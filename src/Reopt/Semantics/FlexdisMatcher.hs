------------------------------------------------------------------------
-- |
-- Module           : Reopt.Semantics.FlexdisMatcher
-- Description      : Pattern matches against a Flexdis86 InstructionInstance.
-- Copyright        : (c) Galois, Inc 2015
-- Maintainer       : Joe Hendrix <jhendrix@galois.com>
-- Stability        : provisional
--
-- This contains a function "execInstruction" that steps a single Flexdis86
-- instruction.
------------------------------------------------------------------------
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TypeFamilies #-}
module Reopt.Semantics.FlexdisMatcher
  ( execInstruction
  ) where

import qualified Flexdis86 as F
import Reopt.Semantics
import Reopt.Semantics.Monad

import Data.Parameterized.NatRepr

data SomeBV v where
  SomeBV :: SupportedBVWidth v n => v (BVType n) -> SomeBV v

getValue :: FullSemantics m => F.Value -> m (SomeBV (Value m))
getValue = undefined

getBVLocation :: NatRepr n -> F.Value -> m (MLocation m (BVType n))
getBVLocation = undefined

binop :: FullSemantics m => (forall n. IsLocationBV m n => MLocation m (BVType n) -> Value m (BVType n) -> m ()) -> [F.Value] -> m ()
binop f [loc, val] = do SomeBV v <- getValue val
                        l <- getBVLocation (bv_width v) loc
                        f l v
binop _f vs        = error $ "binop: expecting 2 arguments, got " ++ show (length vs)

execInstruction :: FullSemantics m => F.InstructionInstance -> m ()
execInstruction ii =
  case (F.iiOp ii, F.iiArgs ii) of
    ("add", vs) -> binop exec_add vs
    _ -> fail $ "Unsupported instruction: " ++ show ii
