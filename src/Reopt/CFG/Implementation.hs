{-
Module           : Reopt.Semantics.Implementation
Copyright        : (c) Galois, Inc 2015
Maintainer       : Joe Hendrix <jhendrix@galois.com>

This contains an implementation of the classes defined in Reopt.Semantics.Monad
that map  a control flow graph from a program using the semantics.
-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE PatternGuards #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE KindSignatures #-}
{-# OPTIONS_GHC -Werror #-}
module Reopt.CFG.Implementation
       ( -- * The main disassemble function
         disassembleBlock
       , ExploreLoc(..)
       , rootLoc
       ) where

import           Control.Exception (assert)
import           Control.Lens
import           Control.Monad.Cont
import           Control.Monad.State.Strict
import           Data.Bits
import qualified Data.Foldable as Fold
import           Data.Maybe
import           Data.Parameterized.Map (MapF)
import qualified Data.Parameterized.Map as MapF
import           Data.Parameterized.NatRepr
import           Data.Parameterized.Some
import           Data.Sequence (Seq)
import qualified Data.Sequence as Seq
import qualified Data.Text as Text
import           Data.Word
import qualified Flexdis86 as Flexdis
import           Numeric (showHex)
import           Text.PrettyPrint.ANSI.Leijen (Pretty(..), text, colon, (<>), (<+>))

import           Data.Macaw.CFG
import           Data.Macaw.Types (BVType, typeRepr)

import qualified Reopt.Machine.StateNames as N
import           Reopt.Machine.X86State
import           Reopt.Object.Memory
import           Reopt.Semantics.FlexdisMatcher (execInstruction)
import           Reopt.Semantics.Monad
  ( BoolType
  , bvLit
  )
import qualified Reopt.Semantics.Monad as S

import           Debug.Trace

------------------------------------------------------------------------
-- Expr

-- | A pure expression for isValue.
data Expr tp where
  -- An expression obtained from some value.
  ValueExpr :: !(Value X86_64 tp) -> Expr tp
  -- An expression that is computed from evaluating subexpressions.
  AppExpr :: !(App Expr tp) -> Expr tp

instance Eq (Expr tp) where
  (==) = \x y -> isJust (testEquality x y)

instance TestEquality Expr where
  testEquality (ValueExpr x) (ValueExpr y) = do
    Refl <- testEquality x y
    return Refl
  testEquality (AppExpr x) (AppExpr y) = do
    Refl <- testEquality x y
    return Refl
  testEquality _ _ = Nothing

asApp :: Expr tp -> Maybe (App Expr tp)
asApp (AppExpr   a) = Just a
asApp (ValueExpr v) = mapApp ValueExpr <$> valueAsApp v

app :: App Expr tp -> Expr tp
app = AppExpr

exprType :: Expr tp -> S.TypeRepr tp
exprType (ValueExpr v) = typeRepr v
exprType (AppExpr a) = appType a

-- | Return width of expression.
exprWidth :: Expr (BVType n) -> NatRepr n
exprWidth e =
  case exprType e of
    S.BVTypeRepr n -> n

asBVLit :: Expr tp -> Maybe Integer
asBVLit (ValueExpr (BVValue _ v)) = Just v
asBVLit _ = Nothing

ltProof :: forall f n m . (n+1 <= m) => f n -> f m -> LeqProof n m
ltProof _ _ = leqTrans lt LeqProof
  where lt :: LeqProof n (n+1)
        lt = leqAdd LeqProof S.n1

bvSle :: Expr (BVType n) -> Expr (BVType n) -> Expr BoolType
bvSle x y = app (BVSignedLe x y)

bvUle :: Expr (BVType n) -> Expr (BVType n) -> Expr BoolType
bvUle x y = app (BVUnsignedLe x y)

instance S.IsValue Expr where

  bv_width = exprWidth

  mux c x y
    | Just 1 <- asBVLit c = x
    | Just 0 <- asBVLit c = y
    | x == y = x
    | Just (BVComplement _ cn) <- asApp c = app $ Mux (exprWidth x) cn y x
    | otherwise = app $ Mux (exprWidth x) c x y

  bvLit n v = ValueExpr $ mkLit n (toInteger v)
  bvAdd x y
      -- Eliminate add 0
    | Just 0 <- asBVLit y = x
    | Just 0 <- asBVLit x = y

      -- Constant folding.
    | ValueExpr (BVValue w xv) <- x
    , Just yv <- asBVLit y
    = bvLit w (xv + yv)

      -- Shift constants to right-hand-side.
    | Just _ <- asBVLit x = S.bvAdd y x

      -- Reorganize addition by constant to offset.
    | Just (BVAdd w x_base (asBVLit -> Just x_off)) <- asApp x
    , Just y_off <- asBVLit y
    = S.bvAdd x_base (bvLit w (x_off + y_off))

    | Just (BVAdd w y_base (asBVLit -> Just y_off)) <- asApp y
    , Just x_off <- asBVLit x
    = S.bvAdd y_base (bvLit w (x_off + y_off))

    | otherwise = app $ BVAdd (exprWidth x) x y

  bvSub x y
    | Just yv <- asBVLit y = S.bvAdd x (bvLit (exprWidth x) (negate yv))
    | otherwise = app $ BVSub (exprWidth x) x y

  bvMul x y
    | Just 0 <- asBVLit x = x
    | Just 1 <- asBVLit x = y
    | Just 0 <- asBVLit y = y
    | Just 1 <- asBVLit y = x

    | Just xv <- asBVLit x, Just yv <- asBVLit y =
      bvLit (exprWidth x) (xv * yv)
    | otherwise = app $ BVMul (exprWidth x) x y

  complement x
    | Just xv <- asBVLit x = bvLit (exprWidth x) (complement xv)
      -- not (y < z) = y >= z = z <= y
    | Just (BVUnsignedLt y z) <- asApp x = bvUle z y
      -- not (y <= z) = y > z = z < y
    | Just (BVUnsignedLe y z) <- asApp x = S.bvUlt z y
      -- not (y < z) = y >= z = z <= y
    | Just (BVSignedLt y z) <- asApp x = bvSle z y
      -- not (y <= z) = y > z = z < y
    | Just (BVSignedLe y z) <- asApp x = S.bvSlt z y
      -- not (not p) = p
    | Just (BVComplement _ y) <- asApp x = y
    | otherwise = app $ BVComplement (exprWidth x) x

  x .&. y
    | Just xv <- asBVLit x, Just yv <- asBVLit y =
      bvLit (exprWidth x) (xv .&. yv)
      -- Eliminate and when one argument is maxUnsigned
    | Just xv <- asBVLit x, xv == maxUnsigned (exprWidth x) = y
    | Just yv <- asBVLit y, yv == maxUnsigned (exprWidth x) = x
      -- Cancel when and with 0.
    | Just 0 <- asBVLit x = x
    | Just 0 <- asBVLit y = y
      -- Idempotence
    | x == y = x
      -- x1 <= x2 & x1 ~= x2 = x1 < x2
    | Just (BVUnsignedLe x1 x2) <- asApp x
    , Just (BVComplement _ yc) <- asApp y
    , Just (BVEq y1 y2) <- asApp yc
    , Just Refl <- testEquality (exprWidth x1) (exprWidth y1)
    , ((x1,x2) == (y1,y2) || (x1,x2) == (y2,y1)) =
      S.bvUlt x1 x2
      -- x1 ~= x2 & x1 <= x2 => x1 < x2
    | Just (BVUnsignedLe y1 y2) <- asApp y
    , Just (BVComplement _ xc) <- asApp x
    , Just (BVEq x1 x2) <- asApp xc
    , Just Refl <- testEquality (exprWidth x1) (exprWidth y1)
    , ((x1,x2) == (y1,y2) || (x1,x2) == (y2,y1)) =
      S.bvUlt y1 y2
      -- Default case
    | otherwise = app $ BVAnd (exprWidth x) x y

  x .|. y
    | Just xv <- asBVLit x, Just yv <- asBVLit y =
      bvLit (exprWidth x) (xv .|. yv)
      -- Cancel or when one argument is maxUnsigned
    | Just xv <- asBVLit x, xv == maxUnsigned (exprWidth x) = x
    | Just yv <- asBVLit y, yv == maxUnsigned (exprWidth x) = y
      -- Eliminate "or" when one argument is 0
    | Just 0 <- asBVLit x = y
    | Just 0 <- asBVLit y = x
      -- Idempotence
    | x == y = x

      -- Rewrite "x < y | x == y" to "x <= y"
    | Just (BVUnsignedLt x1 x2) <- asApp x
    , Just (BVEq y1 y2) <- asApp y
    , Just Refl <- testEquality (exprWidth x1) (exprWidth y1)
    , (x1,x2) == (y1,y2) || (x1,x2) == (y2,y1)
    = bvUle x1 x2

      -- Default case
    | otherwise = app $ BVOr (exprWidth x) x y

  bvXor x y
      -- Eliminate xor with 0.
    | Just 0 <- asBVLit x = y
    | Just 0 <- asBVLit y = x
      -- Eliminate xor with self.
    | x == y = bvLit (exprWidth x) (0::Integer)
      -- Default case.
    | otherwise = app $ BVXor (exprWidth x) x y

  x .=. y
    | x == y = S.true
      -- Add two literals.
    | Just xv <- asBVLit x, Just yv <- asBVLit y = S.boolValue (xv == yv)
      -- Move constant to second argument
    | Just _ <- asBVLit x = y S..=. x

      -- Rewrite "base + offset = constant" to "base = constant - offset".
    | Just (BVAdd w x_base (asBVLit -> Just x_off)) <- asApp x
    , Just yv <- asBVLit y =
      app $ BVEq x_base (bvLit w (yv - x_off))
      -- Rewrite "u - v == c" to "u = c + v".
    | Just (BVSub _ x_1 x_2) <- asApp x = x_1 S..=. S.bvAdd y x_2
      -- Rewrite "c == u - v" to "u = c + v".
    | Just (BVSub _ y_1 y_2) <- asApp y = y_1 S..=. S.bvAdd x y_2

    | otherwise = app $ BVEq x y

  -- | Splits a bit vectors into two
  -- bvSplit :: v (BVType (n + n)) -> (v (BVType n), v (BVType n))
  bvSplit v = (upperHalf v, lowerHalf v)

  -- | Shifts, the semantics is undefined for shifts >= the width of the first argument
  -- bvShr, bvSar, bvShl :: v (BVType n) -> v (BVType log_n) -> v (BVType n)
  bvShr x y
    | Just 0 <- asBVLit y = x
    | Just 0 <- asBVLit x = x
    | otherwise = app $ BVShr (exprWidth x) x y
  bvSar x y = app $ BVSar (exprWidth x) x y

  bvShl x y
    | Just 0 <- asBVLit y = x

    | Just xv <- asBVLit x
    , Just yv <- asBVLit y =
      assert (yv <= toInteger (maxBound :: Int)) $
        bvLit (exprWidth x) (xv `shiftL` fromInteger yv)

      -- Replace "(x >> c) << c" with (x .&. - 2^c)
    | Just yv <- asBVLit y
    , Just (BVShr w x_base (asBVLit -> Just x_shft)) <- asApp x
    , x_shft == yv =
      x_base S..&. bvLit w (negate (2^x_shft) ::Integer)

    | Just yv <- asBVLit y
    , yv >= natValue (exprWidth x) = bvLit (exprWidth x) (0 :: Integer)

    | otherwise = app $ BVShl (exprWidth x) x y

  bvTrunc' w e0
    | Just v <- asBVLit e0 =
      bvLit w v
    | Just Refl <- testEquality (exprWidth e0) w =
      e0
    | Just (MMXExtend e) <- asApp e0
    , Just Refl <- testEquality w n64 =
      e
    -- WARNING: the 'ConcatV' here appears to be little endian,
    -- whereas 'bvCat' in 'IsValue' is big endian. Is this a bug?
    | Just (ConcatV lw _ l _) <- asApp e0
    , Just LeqProof <- testLeq w lw =
      S.bvTrunc w l
    | Just (UExt e _) <- asApp e0 =
      case testLeq w (S.bv_width e) of
        -- Check if original value width is less than new width.
        Just LeqProof -> S.bvTrunc w e
        Nothing ->
          -- Runtime check to wordaround GHC typechecker
          case testLeq (S.bv_width e) w of
            Just LeqProof -> S.uext w e
            Nothing -> error "bvTrunc internal error"
      -- Trunc (x .&. y) w = trunc x w .&. trunc y w
    | Just (BVAnd _ x y) <- asApp e0 =
      let x' = S.bvTrunc' w x
          y' = S.bvTrunc' w y
       in x' S..&. y'
      -- trunc (Trunc e w1) w2 = trunc e w2
    | Just (Trunc e _) <- asApp e0 =
      -- Runtime check to workaround GHC typechecker.
      case testLeq w (exprWidth e) of
        Just LeqProof -> S.bvTrunc w e
        Nothing -> error "bvTrunc given bad width"
      -- Default case
    | otherwise = app (Trunc e0 w)

  bvUlt x y
    | Just xv <- asBVLit x, Just yv <- asBVLit y = S.boolValue (xv < yv)
    | x == y = S.false
    | otherwise = app $ BVUnsignedLt x y

  bvSlt x y
    | Just xv <- asBVLit x, Just yv <- asBVLit y = S.boolValue (xv < yv)
    | x == y = S.false
    | otherwise = app $ BVSignedLt x y

  bvBit x y
    | Just xv <- asBVLit x
    , Just yv <- asBVLit y =
      S.boolValue (xv `testBit` fromInteger yv)
    | Just (Trunc xe w) <- asApp x
    , Just yv <- asBVLit y = assert (0 <= yv && yv < natValue w) $
      S.bvBit xe y

    | Just (ConcatV lw _lw' x_low x_high) <- asApp x
    , Just yv <- asBVLit y = assert (0 <= yv && yv < 2*natValue lw) $
      if yv >= natValue lw then
        S.bvBit x_high (S.bvLit (exprWidth y) (yv - natValue lw))
      else
        S.bvBit x_low y

    | otherwise =
      app $ BVTestBit x y

  sext' w e0
      -- Collapse duplicate extensions.
    | Just (SExt e w0) <- asApp e0 = do
      let we = S.bv_width e
      withLeqProof (leqTrans (ltProof we w0) (ltProof w0 w)) $
        S.sext w e
    | otherwise = app (SExt e0 w)

  uext' w e0
      -- Literal case
    | Just v <- asBVLit e0 =
      let w0 = S.bv_width e0
       in withLeqProof (leqTrans (leqProof S.n1 w0) (ltProof w0 w)) $
            bvLit w v
      -- Collapse duplicate extensions.
    | Just (UExt e w0) <- asApp e0 = do
      let we = S.bv_width e
      withLeqProof (leqTrans (ltProof we w0) (ltProof w0 w)) $
        S.uext w e

{-
      -- Convert @uext w (trunc w0 e)@ into @e .&. (2^w0 - 1)@
      -- We have disabled this because our abstract domains are not as precise.
    | Just (Trunc e w0) <- asApp e0
    , Just Refl <- testEquality (S.bv_width e) w = do
      withLeqProof (leqTrans (leqProof S.n1 w0) (ltProof w0 w)) $
        e S..&. bvLit w (maxUnsigned w0)
-}

      -- Default case
    | otherwise = app (UExt e0 w)

  even_parity x
    | Just xv <- asBVLit x =
        let go 8 r = r
            go i r = go (i+1) $! (xv `testBit` i /= r)
         in S.boolValue (go 0 True)
    | otherwise = app $ EvenParity x
  reverse_bytes x = app $ ReverseBytes (exprWidth x) x

  uadc_overflows x y c
    | Just 0 <- asBVLit y, Just 0 <- asBVLit c = S.false
    | otherwise = app $ UadcOverflows (exprWidth x) x y c
  sadc_overflows x y c
    | Just 0 <- asBVLit y, Just 0 <- asBVLit c = S.false
    | otherwise = app $ SadcOverflows (exprWidth x) x y c

  usbb_overflows x y c
    | Just 0 <- asBVLit y, Just 0 <- asBVLit c = S.false
      -- If the borrow bit is zero, this is equivalent to unsigned x < y.
    | Just 0 <- asBVLit c = S.bvUlt x y
    | otherwise = app $ UsbbOverflows (exprWidth x) x y c

  ssbb_overflows x y c
    | Just 0 <- asBVLit y, Just 0 <- asBVLit c = S.false
      -- If the borrow bit is zero, this is equivalent to signed x < y.
      -- FIXME: not true? | Just 0 <- asBVLit c = app $ BVSignedLt x y
    | otherwise = app $ SsbbOverflows (exprWidth x) x y c

  bsf x = app $ Bsf (exprWidth x) x
  bsr x = app $ Bsr (exprWidth x) x

  isQNaN rep x = app $ FPIsQNaN rep x
  isSNaN rep x = app $ FPIsSNaN rep x

  fpAdd rep x y = app $ FPAdd rep x y
  fpAddRoundedUp rep x y = app $ FPAddRoundedUp rep x y

  fpSub rep x y = app $ FPSub rep x y
  fpSubRoundedUp rep x y = app $ FPSubRoundedUp rep x y

  fpMul rep x y = app $ FPMul rep x y
  fpMulRoundedUp rep x y = app $ FPMulRoundedUp rep x y

  fpDiv rep x y = app $ FPDiv rep x y

  fpLt rep x y = app $ FPLt rep x y
  fpEq rep x y = app $ FPEq rep x y

  fpCvt src tgt x = app $ FPCvt src x tgt
  fpCvtRoundsUp src tgt x = app $ FPCvtRoundsUp src x tgt

  fpFromBV tgt x = app $ FPFromBV x tgt
  truncFPToSignedBV tgt src x = app $ TruncFPToSignedBV src x tgt

------------------------------------------------------------------------
-- GenState

-- | A block that we have not yet finished.
data PreBlock = PreBlock { pBlockLabel  :: !(BlockLabel Word64)
                         , _pBlockStmts :: !(Seq (Stmt X86_64))
                         , _pBlockState :: !(X86State (Value X86_64))
                         , _pBlockApps  :: !(MapF (App (Value X86_64)) (Assignment X86_64))
                         }

pBlockStmts :: Simple Lens PreBlock (Seq (Stmt X86_64))
pBlockStmts = lens _pBlockStmts (\s v -> s { _pBlockStmts = v })

pBlockState :: Simple Lens PreBlock (X86State (Value X86_64))
pBlockState = lens _pBlockState (\s v -> s { _pBlockState = v })

pBlockApps  :: Simple Lens PreBlock (MapF (App (Value X86_64)) (Assignment X86_64))
pBlockApps = lens _pBlockApps (\s v -> s { _pBlockApps = v })

-- | A tagged maybe
data MaybeF (t :: Bool) a where
  NothingF :: MaybeF 'False a
  JustF    :: a -> MaybeF 'True a

_JustF :: Lens (MaybeF 'True a) (MaybeF 'True b) a b
_JustF = lens (\(JustF v) -> v) (\_ v -> JustF v)

-- | Local to block discovery.
data GenState tag = GenState
       { _nextAssignID :: !AssignId
         -- ^ The next id to use for assignments
       , _nextBlockID  :: !Word64
         -- ^ Index of next block
       , _frontierBlocks :: !(Seq (Block X86_64))
         -- ^ Blocks added to CFG
       , _blockState     :: !(MaybeF tag PreBlock)
         -- ^ Blocks generated so far
       }

-- | Next identifier to use for assignments.
nextAssignID :: Simple Lens (GenState tag) AssignId
nextAssignID = lens _nextAssignID (\s v -> s { _nextAssignID = v })

-- | Control flow blocs generated so far.
nextBlockID :: Simple Lens (GenState tag) Word64
nextBlockID = lens _nextBlockID (\s v -> s { _nextBlockID = v })

-- | Blocks that are not in CFG that end with a FetchAndExecute,
-- which we need to analyze to compute new potential branch targets.
frontierBlocks :: Simple Lens (GenState tag) (Seq (Block X86_64))
frontierBlocks = lens _frontierBlocks (\s v -> s { _frontierBlocks = v })

-- | Blocks that are not in CFG that end with a FetchAndExecute,
-- which we need to analyze to compute new potential branch targets.
blockState :: Lens (GenState a) (GenState b) (MaybeF a PreBlock) (MaybeF b PreBlock)
blockState = lens _blockState (\s v -> s { _blockState = v })

emptyPreBlock :: X86State (Value X86_64)
              -> BlockLabel Word64
              -> PreBlock
emptyPreBlock s lbl =
  PreBlock { pBlockLabel = lbl
           , _pBlockStmts = Seq.empty
           , _pBlockApps  = MapF.empty
           , _pBlockState = s
           }

emptyGenState :: AssignId -> GenState 'False
emptyGenState n =
  GenState { _nextAssignID   = n
           , _nextBlockID    = 1
           , _frontierBlocks = Seq.empty
           , _blockState     = NothingF
           }

curX86State :: Simple Lens (GenState 'True) (X86State (Value X86_64))
curX86State = blockState . _JustF . pBlockState

-- | Finishes the current block, if it is started.
finishBlock' :: PreBlock
             -> (X86State (Value X86_64) -> TermStmt X86_64)
             -> Block X86_64
finishBlock' pre_b term =
  Block { blockLabel = pBlockLabel pre_b
        , blockStmts = Fold.toList (pre_b^.pBlockStmts)
        , blockCache = pre_b^.pBlockApps
        , blockTerm  = term (pre_b^.pBlockState)
        }

-- | Finishes the current block, if it is started.
finishBlock :: (X86State (Value X86_64) -> TermStmt X86_64)
            -> (GenState a -> GenState 'False)
finishBlock term st =
  case st^.blockState of
   NothingF    -> st
   JustF pre_b -> st & frontierBlocks %~ (Seq.|> b)
                     & blockState .~ NothingF
     where
       b = finishBlock' pre_b term

-- | Starts a new block.  If there is a current block it will finish
-- it with FetchAndExecute
startBlock :: X86State (Value X86_64) -> BlockLabel Word64 -> (GenState a -> GenState 'True)
startBlock s lbl st =
  finishBlock FetchAndExecute st & blockState .~ JustF (emptyPreBlock s lbl)

------------------------------------------------------------------------
-- X86Generator

-- | X86Generator is used to construct basic blocks from a stream of instructions
-- using the semantics.
--
-- It is implemented as a state monad in a continuation passing style so that
-- we can perform symbolic branches.
--
-- This returns either a failure message or the next state.
newtype X86Generator a = X86G { unX86G :: (a -> GenState 'True -> Either String (Some GenState))
                                       -> GenState 'True
                                       -> Either String (Some GenState)
                              }

instance Functor X86Generator where
  fmap = liftM

instance Applicative X86Generator where
  pure = return
  (<*>) = ap

instance Monad X86Generator where
  return v = X86G $ \c -> c v
  m >>= h = X86G $ \c -> unX86G m (\mv -> unX86G (h mv) c)
  fail msg = X86G $ \_ _ -> Left msg

type instance S.Value X86Generator = Expr

-- | Run X86Generator starting from the given state.
runX86Generator :: GenState 'True -> X86Generator () -> Either String (Some GenState)
runX86Generator st m = unX86G m (\() -> Right . Some) st

modGenState :: State (GenState 'True) a -> X86Generator a
modGenState m = X86G $ \c s -> uncurry c (runState m s)

modState :: State (X86State (Value X86_64)) a -> X86Generator a
modState m = modGenState $ do
  s <- use curX86State
  let (r,s') = runState m s
  curX86State .= s'
  return r

-- | Create a new assignment identifier.
newAssignID :: X86Generator AssignId
newAssignID = modGenState $ nextAssignID <<+= 1

addStmt :: Stmt X86_64 -> X86Generator ()
addStmt stmt = modGenState $ blockState . _JustF . pBlockStmts %= (Seq.|> stmt)

addAssignment :: AssignRhs X86_64 tp -> X86Generator (Assignment X86_64 tp)
addAssignment rhs = do
  l <- newAssignID
  let a = Assignment l rhs
  addStmt $ AssignStmt a
  return a

-- | This function does a top-level constant propagation/constant reduction.
-- We assuem that the leaf nodes have also been propagated (i.e., we only operate
-- at the outermost term)

-- FIXME: make less ad-hoc
constPropagate :: forall tp. App (Value X86_64) tp -> Maybe (Value X86_64 tp)
constPropagate v =
  case v of
   BVAnd _ l r
     | Just _ <- testEquality l r -> Just l
   BVAnd sz l r                   -> binop (.&.) sz l r
   -- Units
   BVAdd _  l (BVValue _ 0)       -> Just l
   BVAdd _  (BVValue _ 0) r       -> Just r
   BVAdd sz l r                   -> binop (+) sz l r
   BVMul _  l (BVValue _ 1)       -> Just l
   BVMul _  (BVValue _ 1) r       -> Just r

   UExt  (BVValue _ n) sz         -> Just $ mkLit sz n

   -- Word operations
   Trunc (BVValue _ x) sz         -> Just $ mkLit sz x

   -- Boolean operations
   BVUnsignedLt l r               -> boolop (<) l r
   BVEq l r                       -> boolop (==) l r
   BVComplement sz x              -> unop complement sz x
   _                              -> Nothing
  where
    boolop :: (tp ~ BoolType)
           => (Integer -> Integer -> Bool)
           -> Value X86_64 utp -> Value X86_64 utp -> Maybe (Value X86_64 BoolType)
    boolop f (BVValue _ l) (BVValue _ r) = Just $ mkLit knownNat (if f l r then 1 else 0)
    boolop _ _ _ = Nothing

    unop :: (tp ~ BVType n)
         => (Integer -> Integer)
         -> NatRepr n -> Value X86_64 tp -> Maybe (Value X86_64 tp)
    unop f sz (BVValue _ l)  = Just $ mkLit sz (f l)
    unop _ _ _               = Nothing

    binop :: (tp ~ BVType n) => (Integer -> Integer -> Integer)
          -> NatRepr n
          -> Value X86_64 tp
          -> Value X86_64 tp
          -> Maybe (Value X86_64 tp)
    binop f sz (BVValue _ l) (BVValue _ r) = Just $ mkLit sz (f l r)
    binop _ _ _ _                          = Nothing

evalApp :: App (Value X86_64) tp  -> X86Generator (Value X86_64 tp)
evalApp a = do
  case constPropagate a of
    Nothing -> do
      m <- modGenState $ use (blockState . _JustF . pBlockApps)
      case MapF.lookup a m of
        Nothing -> do
          r <- addAssignment (EvalApp a)
          modGenState $ (blockState . _JustF . pBlockApps) %= MapF.insert a r
          return (AssignedValue r)
        Just r -> return (AssignedValue r)
    Just v  -> return v

eval :: Expr tp -> X86Generator (Value X86_64 tp)
eval (ValueExpr v) = return v
eval (AppExpr a) = evalApp =<< traverseApp eval a

-- | Type for addresses.
type AddrExpr = Expr (BVType 64)

------------------------------------------------------------------------
-- Location

type ImpLocation tp = S.Location AddrExpr tp

getX87Top :: X86Generator Int
getX87Top = do
  top_val <- modState $ use $ x87TopReg
  case top_val of
    -- Validate that i is less than top and top +
    BVValue _ (fromInteger -> top) ->
      return top
    _ -> fail $ "Unsupported value for top register " ++ show (pretty top_val)

getX87Offset :: Int -> X86Generator Int
getX87Offset i = do
  top <- getX87Top
  unless (0 <= top + i && top + i <= 7) $ do
    fail $ "Illegal floating point index"
  return $! top + i

readLoc :: X86PrimLoc tp -> X86Generator (Expr tp)
readLoc l = ValueExpr . AssignedValue <$> addAssignment (EvalArchFn (ReadLoc l))

getLoc :: ImpLocation tp -> X86Generator (Expr tp)
getLoc l0 =
  case l0 of
    S.MemoryAddr w tp -> do
      addr <- eval w
      ValueExpr . AssignedValue <$> addAssignment (ReadMem addr tp)
    S.Register rv -> do
      let readLoc' l = S.registerViewRead rv <$> readLoc l
      let r_nm = S.registerViewReg rv
      case r_nm of
       -- N.ControlReg {} -> addStmt $ Val (ControlLoc r) v
       -- N.DebugReg {}   -> addStmt $ Write (DebugLoc r)   v
       N.SegmentReg {}
         | r_nm == N.fs -> readLoc' FS
         | r_nm == N.gs -> readLoc' GS
         -- Otherwise registers are 0.
         | otherwise ->
           fail $ "On x86-64 registers other than fs and gs may not be read."
       N.X87PC -> readLoc' X87_PC
       N.X87RC -> readLoc' X87_RC
       _ -> do
         let Just r = x86Reg r_nm
         modState $
            S.registerViewRead rv . ValueExpr <$> use (boundValue r)
    -- TODO
    S.X87StackRegister i -> do
      idx <- getX87Offset i
      e <- modState $ use $ boundValue (X87_FPUReg idx)
      -- TODO: Check tag register is assigned.
      return $! ValueExpr e

lowerHalf :: forall n . (1 <= n) => Expr (BVType (n+n)) -> Expr (BVType n)
lowerHalf e =
     -- Workaround for GHC typechecker
     withLeqProof (addIsLeq half_width half_width) $ do
       S.bvTrunc half_width e
  where half_width :: NatRepr n
        half_width = halfNat (exprWidth e)

n64 :: NatRepr 64
n64 = knownNat

-- | Get the upper half of a bitvector.
upperHalf :: forall n . (1 <= n) => Expr (BVType (n+n)) -> Expr (BVType n)
-- Handle concrete values
upperHalf (ValueExpr (BVValue w i)) = h
   where half_width = halfNat w
         h = bvLit half_width (i `shiftR` widthVal half_width)
upperHalf e =
   case asApp e of
      -- Handle expression concatenation.
      -- N.B. We use unsafe coerce due to GHC failing to match the (n+n) in upperHalf
      -- to the (n+n) bound in ConcatV.
      Just (ConcatV lw lw' _ h)
        | Just Refl <- testEquality lw lw' -> do
        case testEquality half_width (exprWidth h) of
          Just Refl -> h
          Nothing -> error "upper half given illegal widths."
      -- Introduce split operations
      _ ->
        -- Workaround for GHC typechecker
        withLeqProof (addIsLeq half_width half_width) $
          app (UpperHalf half_width e)
  where half_width :: NatRepr n
        half_width = halfNat (exprWidth e)

-- | Assign a value to a location
setLoc :: forall tp. ImpLocation tp -> Value X86_64 tp -> X86Generator ()
setLoc loc v =
  case loc of
   S.MemoryAddr w _ -> do
     addr <- eval w
     addStmt $ WriteMem addr v

   S.Register rv -> do
     let writeReg reg = do
           v0 <- readLoc reg
           v1 <- eval $ S.registerViewWrite rv v0 (ValueExpr v)
           addStmt $ ExecArchStmt $ WriteLoc reg v1
     let r_nm = S.registerViewReg rv
     case r_nm of
       N.ControlReg {} -> writeReg (ControlLoc r_nm)
       N.DebugReg {}   -> writeReg (DebugLoc r_nm)
       N.SegmentReg {}
         | r_nm == N.fs -> writeReg FS
         | r_nm == N.gs -> writeReg GS
         -- Otherwise registers are 0.
         | otherwise ->
             fail $ "On x86-64 registers other than fs and gs may not be set."
       N.X87PC -> writeReg X87_PC
       N.X87RC -> writeReg X87_RC
       _ -> do
         let Just r = x86Reg r_nm
         v0 <- modState $ ValueExpr <$> use (boundValue r)
         v1 <- eval $ S.registerViewWrite rv v0 (ValueExpr v)
         modState $ boundValue r .= v1
   S.X87StackRegister i -> do
     off <- getX87Offset i
     modState $ boundValue (X87_FPUReg off) .= v

mkBlockLabel :: CodeAddr -> GenState any -> (BlockLabel Word64, GenState any)
mkBlockLabel a s0 = (lbl, s1)
  where (b_id, s1) = s0 & nextBlockID <<+~ 1
        lbl = GeneratedBlock a b_id

-- | Helper function for 'S.Semantics' instance below.
bvBinOp :: (NatRepr n -> Value X86_64 tp -> BVValue X86_64 n -> App (Value X86_64) tp1)
        -> Expr tp -> Expr (BVType n) -> X86Generator (Expr tp1)
bvBinOp op' x y = do
  let w = exprWidth y
  xv <- eval x
  yv <- eval y
  zv <- evalApp (op' w xv yv)
  return $ ValueExpr zv

instance S.Semantics X86Generator where
  make_undefined (S.BVTypeRepr n) =
    ValueExpr . AssignedValue <$> addAssignment (SetUndefined n)

  -- Get value of a location.
  get = getLoc

  l .= e = setLoc l =<< eval e

  -- Implement ifte_
  -- Note that this implementation will run any code appearing after the ifte_
  -- twice, once for the true branch and once for the false branch.
  --
  -- This could be changed to run the code afterwards once, but the cost would be
  -- defining a way to merge processor states from the different branches, and making
  -- sure that expression assignments generated in one branch were not referred to in
  -- another branch.
  --
  -- One potential design change, not implemented here, would be to run both branches,
  -- up to the point where they merge, and if the resulting PC is in the same location,
  -- to merge in that case, otherwise to run them separately.
  --
  -- This would support the cmov instruction, but result in divergence for branches, which
  -- I think is what we want.
  ifte_ c_expr t f = eval c_expr >>= go
    where
      go (BVValue _ 1) = t
      go (BVValue _ 0) = f
      go cond =
        X86G $ \c s0 -> do
          let p_b = s0 ^. (blockState . _JustF)
          let st = p_b^.pBlockState
          let a  = labelAddr (pBlockLabel p_b)
          let (t_block_label, s1) = mkBlockLabel a s0
          let s2 = s1 & blockState .~ JustF (emptyPreBlock st t_block_label)
                      & frontierBlocks .~ Seq.empty
          -- Run true block.
          Some (finishBlock FetchAndExecute -> s3) <- unX86G t c s2
          -- Run false block
          let (f_block_label, s4) = mkBlockLabel a s3
          let s5 = s4 & blockState .~ JustF (emptyPreBlock st f_block_label)
                      & frontierBlocks .~ Seq.empty
          Some (finishBlock FetchAndExecute -> s6) <- unX86G f c s5

          -- Join results together.
          let fin_b = finishBlock' p_b (\_ -> Branch cond t_block_label f_block_label)
          pure $ Some $ s6 & frontierBlocks .~ (s0^.frontierBlocks Seq.|> fin_b)
                                               Seq.>< s3^.frontierBlocks
                                               Seq.>< s6^.frontierBlocks
                           & blockState .~ NothingF

  memcopy val_sz count src dest is_reverse = do
    count_v <- eval count
    src_v   <- eval src
    dest_v  <- eval dest
    is_reverse_v <- eval is_reverse
    addStmt $ ExecArchStmt $ MemCopy val_sz count_v src_v dest_v is_reverse_v

  memcmp sz count src dest is_reverse = do
    count_v <- eval count
    is_reverse_v <- eval is_reverse
    src_v   <- eval src
    dest_v  <- eval dest
    ValueExpr . AssignedValue
      <$> addAssignment (EvalArchFn (MemCmp sz count_v src_v dest_v is_reverse_v))

  memset count val dest df = do
    count_v <- eval count
    val_v   <- eval val
    dest_v  <- eval dest
    df_v    <- eval df
    addStmt $ ExecArchStmt $ MemSet count_v val_v dest_v df_v

  find_element sz findEq count buf val is_reverse = do
    count_v <- eval count
    buf_v   <- eval buf
    val_v   <- eval val
    is_reverse_v <- eval is_reverse
    ValueExpr . AssignedValue
      <$> addAssignment (EvalArchFn (FindElement sz findEq count_v buf_v val_v is_reverse_v))

  primitive S.Syscall = do
    X86G $ \_ s0 -> do
      -- Get last block.
      let p_b = s0 ^. (blockState . _JustF)
      -- Create finished block.
      let fin_b = finishBlock' p_b Syscall
      -- Return early
      pure $ Some $ s0 & frontierBlocks %~ (Seq.|> fin_b)
                       & blockState .~ NothingF

  primitive S.CPUID = error "CPUID"
  primitive S.RDTSC = error "RDTSC"
  primitive S.XGetBV = error "XGetBV"

  getSegmentBase seg =
    case seg of
      Flexdis.FS -> ValueExpr . AssignedValue <$> addAssignment (EvalArchFn ReadFSBase)
      Flexdis.GS -> ValueExpr . AssignedValue <$> addAssignment (EvalArchFn ReadGSBase)
      _ ->
        error $ "Reopt.CFG.Implementation.getSegmentBase " ++ show seg ++ ": unimplemented!"

  bvQuot       = bvBinOp BVQuot
  bvSignedQuot = bvBinOp BVSignedQuot
  bvRem        = bvBinOp BVRem
  bvSignedRem  = bvBinOp BVSignedRem

  -- exception :: Value m BoolType    -- mask
  --            -> Value m BoolType -- predicate
  --            -> ExceptionClass
  --            -> m ()
  exception m p c =
    S.ifte_ (S.complement m S..&. p)
            (addStmt (PlaceHolderStmt [] $ "Exception " ++ (show c)))
            (return ())

  x87Push e = do
    v <- eval e
    top <- getX87Top
    let new_top = (top - 1) .&. 0x7
    modState $ do
      -- TODO: Update tagWords
      -- Store value at new top
      boundValue (X87_FPUReg new_top) .= v
      -- Update top
      x87TopReg .= BVValue knownNat (toInteger new_top)
  x87Pop = do
    top <- getX87Top
    let new_top = (top + 1) .&. 0x7
    modState $ do
      -- Update top
      x87TopReg .= BVValue knownNat (toInteger new_top)

    return ()

-- | A location to explore
data ExploreLoc
   = ExploreLoc { loc_ip :: CodeAddr
                  -- ^ IP address.
                , loc_x87_top :: Int
                  -- ^ Top of x86 address.
                }
 deriving (Eq, Ord)

instance Pretty ExploreLoc where
  pretty loc = text $ showHex (loc_ip loc) ""

rootLoc :: CodeAddr -> ExploreLoc
rootLoc ip = ExploreLoc { loc_ip = ip
                        , loc_x87_top = 0
                        }

initX86State :: ExploreLoc -- ^ Location to explore from.
             -> X86State (Value X86_64)
initX86State loc = mkX86State Initial
                 & curIP     .~ mkLit knownNat (toInteger (loc_ip loc))
                 & x87TopReg .~ mkLit knownNat (toInteger (loc_x87_top loc))

data GenError = DecodeError CodeAddr (MemoryError Word64)
              | DisassembleError Flexdis.InstructionInstance
                deriving Show

initGenState :: AssignId -> Word64 -> X86State (Value X86_64) -> GenState 'True
initGenState a_id ip s = startBlock s lbl (emptyGenState a_id)
  where lbl = GeneratedBlock ip 0

-- | Disassemble block, returning either an error, or a list of blocks
-- and ending PC.
disassembleBlock :: AssignId
                    -- ^ Index to use for next assignment
                 -> Memory Word64
                 -> (CodeAddr -> Bool)
                    -- ^ PRedicate that tells when to continue.
                 -> ExploreLoc -- ^ Location to explore from.
                 -> Either GenError ([Block X86_64], CodeAddr, AssignId)
disassembleBlock next_id mem contFn loc = do
  let gs = initGenState next_id (loc_ip loc) (initX86State loc)
  (gs', ip) <- disassembleBlock' mem gs contFn (loc_ip loc)
  return (Fold.toList (gs'^.frontierBlocks), ip, gs' ^.nextAssignID)


{-
getExploreLocs :: X86State -> [ExploreLoc]
getExploreLocs s =
  case (s^.curIP, s^.x87TopReg) of
    (BVValue _ ip, BVValue _ top) -> [loc]
      where loc = ExploreLoc { loc_ip = fromInteger ip
                             , loc_x87_top = fromInteger top
                             }
    _ -> []

getFrontierNext :: [Block] -> Set ExploreLoc
getFrontierNext = Fold.foldl' f Set.empty
  where f locs b =
          case blockTerm b of
            FetchAndExecute s -> Fold.foldl' (flip Set.insert) locs (getExploreLocs s)
            _ -> locs
-}

-- | Disassemble block, returning either an error, or a list of blocks
-- and ending PC.
disassembleBlock' :: Memory Word64
                     -- ^ Memory to use for disassembling block
                  -> GenState 'True
                     -- ^ State information for disassembling.
                  -> (CodeAddr -> Bool)
                     -- ^ This function should return true if
                     -- we should keep disassembling when we step
                     -- to the given address with the functions.
                  -> CodeAddr
                     -- ^ Address to disassemble from.
                  -> Either GenError (GenState 'False, CodeAddr)
disassembleBlock' mem gs contFn addr = do
  (i, next_ip) <- readInstruction mem addr
                  & _Left %~ DecodeError addr
  let next_ip_val :: BVValue X86_64 64
      next_ip_val = mkLit n64 (toInteger next_ip)

  let line = text (showHex addr "") <> colon
             <+> Flexdis.ppInstruction next_ip i

  case execInstruction next_ip i of
    Nothing -> Left (DisassembleError i)
    Just exec -> do
      let res = runX86Generator gs $ do
                  addStmt (Comment (Text.pack (show line)))
                  exec
      case res of
        Left msg -> do
          trace ("Error during dissassembly: " ++ msg ++ "\n" ++ show i) $
            Left (DisassembleError i)
        Right (Some gs2) -> do
          case gs2 ^. blockState of
            -- If next ip is exactly the next_ip_val then keep running.
            JustF p_b | Seq.null (gs2^.frontierBlocks)
                      , v <- p_b^.(pBlockState . curIP)
                      , v == next_ip_val
                      , contFn next_ip ->
              disassembleBlock' mem gs2 contFn next_ip
            _ -> return (finishBlock FetchAndExecute gs2, next_ip)
