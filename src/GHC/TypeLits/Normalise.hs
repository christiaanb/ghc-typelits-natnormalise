{-|
Copyright  :  (C) 2015-2016, University of Twente
License    :  BSD2 (see the file LICENSE)
Maintainer :  Christiaan Baaij <christiaan.baaij@gmail.com>

A type checker plugin for GHC that can solve /equalities/ of types of kind
'GHC.TypeLits.Nat', where these types are either:

* Type-level naturals
* Type variables
* Applications of the arithmetic expressions @(+,-,*,^)@.

It solves these equalities by normalising them to /sort-of/
'GHC.TypeLits.Normalise.SOP.SOP' (Sum-of-Products) form, and then perform a
simple syntactic equality.

For example, this solver can prove the equality between:

@
(x + 2)^(y + 2)
@

and

@
4*x*(2 + x)^y + 4*(2 + x)^y + (2 + x)^y*x^2
@

Because the latter is actually the 'GHC.TypeLits.Normalise.SOP.SOP' normal form
of the former.

To use the plugin, add

@
{\-\# OPTIONS_GHC -fplugin GHC.TypeLits.Normalise \#-\}
@

To the header of your file.
-}

{-# LANGUAGE CPP             #-}
{-# LANGUAGE LambdaCase      #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TupleSections   #-}

{-# OPTIONS_HADDOCK show-extensions #-}

#if __GLASGOW_HASKELL__ < 711
{-# OPTIONS_GHC -fno-warn-deprecations #-}
#endif

module GHC.TypeLits.Normalise
  ( plugin )
where

-- external
import Control.Arrow       (second)
import Data.IORef          (IORef, newIORef,readIORef, modifyIORef)
import Data.List           (intersect)
import Data.Maybe          (catMaybes, mapMaybe)
import GHC.TcPluginM.Extra (tracePlugin)
#if __GLASGOW_HASKELL__ < 711
import GHC.TcPluginM.Extra (evByFiat)
#endif

-- GHC API
import Outputable (Outputable (..), (<+>), ($$), text)
import Plugins    (Plugin (..), defaultPlugin)
import TcEvidence (EvTerm (..))
import TcPluginM  (TcPluginM, tcPluginIO, tcPluginTrace, zonkCt)
import TcRnTypes  (Ct, TcPlugin (..), TcPluginResult(..), ctEvidence, ctEvPred,
                   ctPred, isWanted, mkNonCanonical)
import Type       (EqRel (NomEq), Kind, PredTree (EqPred), PredType, Type, TyVar,
                   classifyPredType, getEqPredTys, mkTyVarTy)
import TysWiredIn (typeNatKind)

#if __GLASGOW_HASKELL__ >= 711
import Coercion   (CoercionHole, Role (..), mkForAllCos, mkHoleCo, mkInstCo,
                   mkNomReflCo, mkUnivCo)
import TcPluginM  (newCoercionHole, newFlexiTyVar)
import TcRnTypes  (CtEvidence (..), TcEvDest (..), ctLoc)
import TyCoRep    (UnivCoProvenance (..))
import Type       (mkPrimEqPred)
import TcType     (typeKind)
#else
import TcType              (mkEqPred, typeKind)
import GHC.TcPluginM.Extra (newWantedWithProvenance, failWithProvenace)
#endif
#if __GLASGOW_HASKELL__ >= 711
import TyCoRep       (Type (..))
#else
import TypeRep       (Type (..))
#endif
import TcTypeNats    (typeNatAddTyCon, typeNatExpTyCon, typeNatMulTyCon,
                      typeNatSubTyCon)

import TcTypeNats    (typeNatLeqTyCon)
import Type          (mkNumLitTy,mkTyConApp)
import TysWiredIn    (promotedFalseDataCon, promotedTrueDataCon)

-- internal
import GHC.Extra.Instances () -- Ord instance for Ct
import GHC.TypeLits.Normalise.Unify

-- | To use the plugin, add
--
-- @
-- {\-\# OPTIONS_GHC -fplugin GHC.TypeLits.Normalise \#-\}
-- @
--
-- To the header of your file.
plugin :: Plugin
plugin = defaultPlugin { tcPlugin = const $ Just normalisePlugin }

normalisePlugin :: TcPlugin
normalisePlugin = tracePlugin "ghc-typelits-natnormalise"
  TcPlugin { tcPluginInit  = tcPluginIO $ newIORef []
           , tcPluginSolve = decideEqualSOP
           , tcPluginStop  = const (return ())
           }

decideEqualSOP :: IORef [Ct] -> [Ct] -> [Ct] -> [Ct]
               -> TcPluginM TcPluginResult
decideEqualSOP _          _givens _deriveds []      = return (TcPluginOk [] [])
decideEqualSOP discharged givens  _deriveds wanteds = do
    -- GHC 7.10.1 puts deriveds with the wanteds, so filter them out
    let wanteds' = filter (isWanted . ctEvidence) wanteds
    let unit_wanteds = mapMaybe toNatEquality wanteds'
    case unit_wanteds of
      [] -> return (TcPluginOk [] [])
      _  -> do
        unit_givens <- mapMaybe toNatEquality <$> mapM zonkCt givens
        sr <- simplifyNats (unit_givens ++ unit_wanteds)
        tcPluginTrace "normalised" (ppr sr)
        case sr of
          Simplified _subst evs -> do
            let solved     = filter (isWanted . ctEvidence . (\(_,x,_) -> x)) evs
            discharedWanteds <- tcPluginIO (readIORef discharged)
            let existingWanteds = wanteds' ++ discharedWanteds
            -- Create new wanted constraints
            (solved',newWanteds) <- (second concat . unzip . catMaybes) <$>
                                    mapM (evItemToCt existingWanteds) solved
            -- update set of discharged wanteds
            tcPluginIO (modifyIORef discharged (++ newWanteds))
            -- return
            return (TcPluginOk solved' newWanteds)
#if __GLASGOW_HASKELL__ >= 711
          Impossible eq -> return (TcPluginContradiction [fromNatEquality eq])
#else
          Impossible eq -> failWithProvenace (fromNatEquality eq)
#endif

evItemToCt :: [Ct] -- ^ Existing wanteds
           -> (EvTerm,Ct,CoreUnify CoreNote)
           -> TcPluginM (Maybe ((EvTerm,Ct),[Ct]))
evItemToCt existingWanteds (ev,ct,subst)
    | null newWanteds = return (Just ((ev,ct),[]))
    | otherwise = do
        newWanteds' <- catMaybes <$> mapM (substItemToCt existingWanteds) newWanteds
        -- only allow new (conditional) evidence if conditional wanted constraints
        -- can be added as new work
        if length newWanteds == length newWanteds'
           then return (Just ((ev,ct),newWanteds'))
           else return Nothing
  where
#if __GLASGOW_HASKELL__ >= 711
    newWanteds = filter (isWanted . ctEvidence . snd . siNote) subst
#else
    newWanteds = filter (isWanted . ctEvidence . siNote) subst
#endif


substItemToCt :: [Ct] -- ^ Existing wanteds wanted
              -> UnifyItem TyVar Type CoreNote
              -> TcPluginM (Maybe Ct)
substItemToCt existingWanteds si
  | predicate  `notElem` wantedPreds
  , predicateS `notElem` wantedPreds
#if __GLASGOW_HASKELL__ >= 711
  = return (Just (mkNonCanonical (CtWanted predicate (HoleDest ev) (ctLoc ct))))
#else
  = Just <$> mkNonCanonical <$> newWantedWithProvenance (ctEvidence ct) predicate
#endif
  | otherwise
  = return Nothing
  where
    predicate   = unifyItemToPredType si
    (ty1,ty2)   = getEqPredTys predicate
#if __GLASGOW_HASKELL__ >= 711
    predicateS    = mkPrimEqPred ty2 ty1
    ((ev,_,_),ct) = siNote si
#else
    predicateS  = mkEqPred ty2 ty1
    ct          = siNote si
#endif
    wantedPreds = map ctPred existingWanteds

unifyItemToPredType :: UnifyItem TyVar Type a -> PredType
unifyItemToPredType ui =
#if __GLASGOW_HASKELL__ >= 711
    mkPrimEqPred ty1 ty2
#else
    mkEqPred ty1 ty2
#endif
  where
    ty1 = case ui of
            SubstItem {..} -> mkTyVarTy siVar
            UnifyItem {..} -> reifySOP siLHS
    ty2 = case ui of
            SubstItem {..} -> reifySOP siSOP
            UnifyItem {..} -> reifySOP siRHS

type NatEquality   = (Ct,CoreSOP,CoreSOP)
type NatInEquality = (Ct,CoreSOP)

fromNatEquality :: Either NatEquality NatInEquality -> Ct
fromNatEquality (Left  (ct, _, _)) = ct
fromNatEquality (Right (ct, _))    = ct

#if __GLASGOW_HASKELL__ >= 711
type CoreNote = ((CoercionHole,TyVar,PredType), Ct)
#else
type CoreNote = Ct
#endif

data SimplifyResult
  = Simplified (CoreUnify CoreNote) [(EvTerm,Ct,CoreUnify CoreNote)]
  | Impossible (Either NatEquality NatInEquality)

instance Outputable SimplifyResult where
  ppr (Simplified subst evs) = text "Simplified" $$ ppr subst $$ ppr evs
  ppr (Impossible eq)  = text "Impossible" <+> ppr eq

simplifyNats :: [Either NatEquality NatInEquality]
             -> TcPluginM SimplifyResult
simplifyNats eqs =
    tcPluginTrace "simplifyNats" (ppr eqs) >> simples [] [] [] eqs
  where
    simples :: CoreUnify CoreNote
            -> [Maybe (EvTerm, Ct, CoreUnify CoreNote)]
            -> [Either NatEquality NatInEquality]
            -> [Either NatEquality NatInEquality]
            -> TcPluginM SimplifyResult
    simples subst evs _xs [] = return (Simplified subst (catMaybes evs))
    simples subst evs xs (eq@(Left (ct,u,v)):eqs') = do
      ur <- unifyNats ct (substsSOP subst u) (substsSOP subst v)
      tcPluginTrace "unifyNats result" (ppr ur)
      case ur of
#if __GLASGOW_HASKELL__ >= 711
        Win         -> simples subst (((,,) <$> evMagic ct [] <*> pure ct <*> pure []):evs) []
                               (xs ++ eqs')
        Lose        -> return (Impossible eq)
        Draw []     -> simples subst evs (eq:xs) eqs'
        Draw subst' -> do
          newEvs <- mapM (\si -> (,,) <$> newCoercionHole
                                      <*> newFlexiTyVar typeNatKind
                                      <*> pure (unifyItemToPredType si))
                         subst'
          let subst'' = zipWith (\si ev -> si {siNote = (ev,siNote si)})
                                subst' newEvs
          simples (substsSubst subst'' subst ++ subst'')
            (((,,) <$> evMagic ct newEvs <*> pure ct <*> pure subst''):evs)
            [] (xs ++ eqs')
#else
        Win         -> simples subst (((,,) <$> evMagic ct <*> pure ct <*> pure []):evs) []
                               (xs ++ eqs')
        Lose        -> return (Impossible eq)
        Draw []     -> simples subst evs (eq:xs) eqs'
        Draw subst' -> do
          simples (substsSubst subst' subst ++ subst')
                  (((,,) <$> evMagic ct <*> pure ct <*> pure subst'):evs)
                  [] (xs ++ eqs')

#endif
    simples subst evs xs (eq@(Right (ct,u)):eqs') =
      case isNatural u of
#if __GLASGOW_HASKELL__ >= 711
        Just True  -> simples subst (((,,) <$> evMagic ct [] <*> pure ct <*> pure []):evs) xs eqs'
#else
        Just True  -> simples subst (((,,) <$> evMagic ct <*> pure ct <*> pure []):evs) xs eqs'
#endif
        Just False -> return (Impossible eq)
        Nothing    -> simples subst evs (eq:xs) eqs'

-- Extract the Nat equality constraints
toNatEquality :: Ct -> Maybe (Either NatEquality NatInEquality)
toNatEquality ct = case classifyPredType $ ctEvPred $ ctEvidence ct of
    EqPred NomEq t1 t2
      -> go t1 t2
    _ -> Nothing
  where
    go (TyConApp tc xs) (TyConApp tc' ys)
      | tc == tc'
      , null ([tc,tc'] `intersect` [typeNatAddTyCon,typeNatSubTyCon
                                   ,typeNatMulTyCon,typeNatExpTyCon])
      = case filter (uncurry (/=)) (zip xs ys) of
          [(x,y)] | isNatKind (typeKind x) &&  isNatKind (typeKind y)
                  -> Just (Left (ct, normaliseNat x, normaliseNat y))
          _ -> Nothing
      | tc == typeNatLeqTyCon
      , [x,y] <- xs
      = if tc' == promotedTrueDataCon
           then Just (Right (ct,normaliseNat (mkTyConApp typeNatSubTyCon [y,x])))
           else if tc' == promotedFalseDataCon
                then Just (Right (ct,normaliseNat (mkTyConApp typeNatSubTyCon [x,mkTyConApp typeNatAddTyCon [y,mkNumLitTy 1]])))
                else Nothing

    go x y
      | isNatKind (typeKind x) && isNatKind (typeKind y)
      = Just (Left (ct,normaliseNat x,normaliseNat y))
      | otherwise
      = Nothing

    isNatKind :: Kind -> Bool
    isNatKind = (== typeNatKind)

#if __GLASGOW_HASKELL__ >= 711
evMagic :: Ct -> [(CoercionHole, TyVar, PredType)] -> Maybe EvTerm
evMagic ct evs = case classifyPredType $ ctEvPred $ ctEvidence ct of
  EqPred NomEq t1 t2 ->
    let ctEv = mkUnivCo (PluginProv "ghc-typelits-natnormalise") Nominal t1 t2
        (holes,tvs,preds) = unzip3 evs
        holeEvs = zipWith (\h p -> uncurry (mkHoleCo h Nominal) (getEqPredTys p))
                          holes preds
        natReflCo = mkNomReflCo typeNatKind
        forallEv = mkForAllCos (map (,natReflCo) tvs) ctEv
        finalEv = foldl mkInstCo forallEv holeEvs
    in  Just (EvCoercion finalEv)
  _ -> Nothing
#else
evMagic :: Ct -> Maybe EvTerm
evMagic ct = case classifyPredType $ ctEvPred $ ctEvidence ct of
  EqPred NomEq t1 t2 -> Just (evByFiat "ghc-typelits-natnormalise" t1 t2)
  _                  -> Nothing
#endif
