{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs             #-}
{-# LANGUAGE OverloadedStrings #-}
module Pattern.Gen where

import Control.Monad.Free
       ( Free (..) )
import Data.Bits
       ( shiftL )
import Data.Either
       ( fromRight )
import Data.Functor.Foldable
       ( Fix (..), para )
import Data.List
       ( transpose )
import Data.Maybe
       ( fromJust, isJust, maybe )
import Data.Text
       ( Text, unpack )
import Data.Tuple.Select
       ( sel1, sel2 )
import Kore.AST.Common
       ( And (..), Application (..), AstLocation (..), BuiltinDomain (..),
       Ceil (..), DomainValue (..), Equals (..), Exists (..), Floor (..),
       Forall (..), Id (..), Iff (..), Implies (..), In (..), Next (..),
       Not (..), Or (..), Pattern (..), Rewrites (..), Sort (..),
       SortActual (..), StringLiteral (..), SymbolOrAlias (..), Variable (..) )
import Kore.AST.Kore
       ( CommonKorePattern )
import Kore.AST.MetaOrObject
       ( Object (..) )
import Kore.AST.Sentence
       ( Attributes (..) )
import Kore.ASTHelpers
       ( ApplicationSorts (..) )
import Kore.Attribute.Parser
       ( parseAttributes )
import Kore.Builtin.Hook
       ( Hook (..) )
import Kore.IndexedModule.IndexedModule
       ( KoreIndexedModule )
import Kore.IndexedModule.MetadataTools
       ( MetadataTools (..), extractMetadataTools )
import Kore.Step.StepperAttributes
       ( StepperAttributes (..) )
import Pattern.Parser
       ( AxiomInfo (..), SymLib (..), getTopChildren, unifiedPatternRAlgebra )

import qualified Data.Map as Map

import qualified Everything as P
import qualified Pattern.Type as P
import qualified Pattern as P

parseAtt :: Attributes -> StepperAttributes
parseAtt = fromRight (error "invalid attr") . parseAttributes

bitwidth :: MetadataTools Object Attributes -> Sort Object -> Int
bitwidth tools sort =
  let att = parseAtt $ sortAttributes tools sort
      hookAtt = hook att
  in case getHook hookAtt of
      Just "BOOL.Bool" -> 1
      _ -> error "Unsupported pattern type"

class KoreRewrite a where
  getLeftHandSide :: a -> [CommonKorePattern]
  getRightHandSide :: a -> CommonKorePattern

instance KoreRewrite (Equals lvl CommonKorePattern) where
  getLeftHandSide = getTopChildren . equalsFirst
  getRightHandSide = equalsSecond

instance KoreRewrite (Rewrites lvl CommonKorePattern) where
  getLeftHandSide = (: []) . rewritesFirst
  getRightHandSide = rewritesSecond

data CollectionCons = Concat | Unit | Element

stripLoc :: SymbolOrAlias Object -> SymbolOrAlias Object
stripLoc (SymbolOrAlias (Id name _) s) = (SymbolOrAlias (Id name AstLocationNone) $ map stripLocSort s)
  where
    stripLocSort :: Sort Object -> Sort Object
    stripLocSort (SortActualSort (SortActual (Id x _) args)) = (SortActualSort (SortActual (Id x AstLocationNone) $ map stripLocSort args))
    stripLocSort sort = sort

genPattern :: KoreRewrite pat => MetadataTools Object Attributes -> SymLib -> pat -> [Fix P.Pattern]
genPattern tools (SymLib _ sorts _) rewrite =
  let lhs = getLeftHandSide rewrite
  in map (para (unifiedPatternRAlgebra (error "unsupported: meta level") rAlgebra)) lhs
  where
    rAlgebra :: Pattern Object Variable (CommonKorePattern,
                                         Fix P.Pattern)
             -> Fix P.Pattern
    rAlgebra (ApplicationPattern (Application rawSym ps)) =
      let sym = stripLoc rawSym
          att = fmap unpack $ getHook $ hook $ parseAtt $ symAttributes tools sym
          sort = applicationSortsResult $ symbolOrAliasSorts tools sym
      in case att of
        Just "LIST.concat" -> listPattern sym Concat (map snd ps) (getSym "LIST.element" (sorts Map.! sort))
        Just "LIST.unit" -> listPattern sym Unit [] (getSym "LIST.element" (sorts Map.! sort))
        Just "LIST.element" -> listPattern sym Element (map snd ps) (getSym "LIST.element" (sorts Map.! sort))
        Just "MAP.concat" -> mapPattern sym Concat (map snd ps) (getSym "MAP.element" (sorts Map.! sort))
        Just "MAP.unit" -> mapPattern sym Unit [] (getSym "MAP.element" (sorts Map.! sort))
        Just "MAP.element" -> mapPattern sym Element (map snd ps) (getSym "MAP.element" (sorts Map.! sort))
        Just "SET.concat" -> setPattern sym Concat (map snd ps) (getSym "SET.element" (sorts Map.! sort))
        Just "SET.unit" -> setPattern sym Unit [] (getSym "SET.element" (sorts Map.! sort))
        Just "SET.element" -> setPattern sym Element (map snd ps) (getSym "SET.element" (sorts Map.! sort))
        Just _ -> Fix $ P.Pattern (Left (P.Symbol sym)) Nothing (map snd ps)
        Nothing -> Fix $ P.Pattern (Left (P.Symbol sym)) Nothing (map snd ps)
    rAlgebra (DomainValuePattern (DomainValue sort (BuiltinDomainPattern (Fix (StringLiteralPattern (StringLiteral str)))))) =
      let att = fmap unpack $ getHook $ hook $ parseAtt $ sortAttributes tools sort
      in Fix $ P.Pattern (if att == Just "BOOL.Bool" then case str of
                           "true" -> Right $ P.Literal "1"
                           "false" -> Right $ P.Literal "0"
                           _ -> Right $ P.Literal str
                           else Right $ P.Literal str)
          (if att == Nothing then Just "STRING.String" else att) []
    rAlgebra (VariablePattern (Variable (Id name _) sort)) =
      let att = fmap unpack $ getHook $ hook $ parseAtt $ sortAttributes tools sort
      in Fix $ P.Variable (unpack name) $ maybe "STRING.String" id att
    rAlgebra (AndPattern (And _ p (_,Fix (P.Variable name hookAtt)))) = Fix $ P.As name hookAtt $ snd p
    rAlgebra pat = error $ show pat
    listPattern :: SymbolOrAlias Object
                -> CollectionCons
                -> [Fix P.Pattern]
                -> SymbolOrAlias Object
                -> Fix P.Pattern
    listPattern sym Concat [Fix (P.ListPattern hd Nothing tl _ o), Fix (P.ListPattern hd' frame tl' _ o')] c =
      Fix (P.ListPattern (hd ++ tl ++ hd') frame tl' c $ Fix $ P.Pattern (Left $ P.Symbol sym) Nothing [o, o'])
    listPattern sym Concat [Fix (P.ListPattern hd frame tl _ o), Fix (P.ListPattern hd' Nothing tl' _ o')] c =
      Fix (P.ListPattern hd frame (tl ++ hd' ++ tl') c $ Fix $ P.Pattern (Left $ P.Symbol sym) Nothing [o, o'])
    listPattern sym Concat [Fix (P.ListPattern hd Nothing tl _ o), p@(Fix (P.Variable _ _))] c =
      Fix (P.ListPattern (hd ++ tl) (Just p) [] c $ Fix $ P.Pattern (Left $ P.Symbol sym) Nothing [o, p])
    listPattern sym Concat [Fix (P.ListPattern hd Nothing tl _ o), p@(Fix P.Wildcard)] c =
      Fix (P.ListPattern (hd ++ tl) (Just p) [] c $ Fix $ P.Pattern (Left $ P.Symbol sym) Nothing [o, p])
    listPattern sym Concat [p@(Fix (P.Variable _ _)), Fix (P.ListPattern hd Nothing tl _ o)] c =
      Fix (P.ListPattern [] (Just p) (hd ++ tl) c $ Fix $ P.Pattern (Left $ P.Symbol sym) Nothing [p, o])
    listPattern sym Concat [p@(Fix P.Wildcard), Fix (P.ListPattern hd Nothing tl _ o)] c =
      Fix (P.ListPattern [] (Just p) (hd ++ tl) c $ Fix $ P.Pattern (Left $ P.Symbol sym) Nothing [p, o])
    listPattern sym Unit [] c = Fix (P.ListPattern [] Nothing [] c $ Fix $ P.Pattern (Left $ P.Symbol sym) Nothing [])
    listPattern sym Element [p] c = Fix (P.ListPattern [p] Nothing [] c $ Fix $ P.Pattern (Left $ P.Symbol sym) Nothing [p])
    listPattern _ Concat [_, Fix (P.MapPattern _ _ _ _ _)] _ = error "unsupported list pattern"
    listPattern _ Concat [Fix (P.MapPattern _ _ _ _ _), _] _ = error "unsupported list pattern"
    listPattern _ Concat [_, Fix (P.SetPattern _ _ _ _)] _ = error "unsupported list pattern"
    listPattern _ Concat [Fix (P.SetPattern _ _ _ _), _] _ = error "unsupported list pattern"
    listPattern _ Concat [_, Fix (P.ListPattern _ (Just _) _ _ _)] _ = error "unsupported list pattern"
    listPattern _ Concat [Fix (P.ListPattern _ (Just _) _ _ _), _] _ = error "unsupported list pattern"
    listPattern _ Concat [Fix (P.As _ _ _), _] _ = error "unsupported list pattern"
    listPattern _ Concat [_, Fix (P.As _ _ _)] _ = error "unsupported list pattern"
    listPattern _ Concat [Fix (P.Pattern _ _ _), _] _ = error "unsupported list pattern"
    listPattern _ Concat [_, Fix (P.Pattern _ _ _)] _ = error "unsupported list pattern"
    listPattern _ Concat [Fix P.Wildcard, _] _ = error "unsupported list pattern"
    listPattern _ Concat [Fix (P.Variable _ _), _] _ = error "unsupported list pattern"
    listPattern _ Concat [] _ = error "unsupported list pattern"
    listPattern _ Concat (_:[]) _ = error "unsupported list pattern"
    listPattern _ Concat (_:_:_:_) _ = error "unsupported list pattern"
    listPattern _ Unit (_:_) _ = error "unsupported list pattern"
    listPattern _ Element [] _ = error "unsupported list pattern"
    listPattern _ Element (_:_:_) _ = error "unsupported list pattern"
    mapPattern :: SymbolOrAlias Object
               -> CollectionCons
               -> [Fix P.Pattern]
               -> SymbolOrAlias Object
               -> Fix P.Pattern
    mapPattern sym Concat [Fix (P.MapPattern ks vs Nothing _ o), Fix (P.MapPattern ks' vs' frame _ o')] c =
      Fix (P.MapPattern (ks ++ ks') (vs ++ vs') frame c $ Fix $ P.Pattern (Left $ P.Symbol sym) Nothing [o, o'])
    mapPattern sym Concat [Fix (P.MapPattern ks vs frame _ o), Fix (P.MapPattern ks' vs' Nothing _ o')] c =
      Fix (P.MapPattern (ks ++ ks') (vs ++ vs') frame c $ Fix $ P.Pattern (Left $ P.Symbol sym) Nothing [o, o'])
    mapPattern sym Concat [Fix (P.MapPattern ks vs Nothing _ o), p@(Fix (P.Variable _ _))] c =
      Fix (P.MapPattern ks vs (Just p) c $ Fix $ P.Pattern (Left $ P.Symbol sym) Nothing [o, p])
    mapPattern sym Concat [Fix (P.MapPattern ks vs Nothing _ o), p@(Fix P.Wildcard)] c =
      Fix (P.MapPattern ks vs (Just p) c $ Fix $ P.Pattern (Left $ P.Symbol sym) Nothing [o, p])
    mapPattern sym Concat [p@(Fix (P.Variable _ _)), Fix (P.MapPattern ks vs Nothing _ o)] c =
      Fix (P.MapPattern ks vs (Just p) c $ Fix $ P.Pattern (Left $ P.Symbol sym) Nothing [p, o])
    mapPattern sym Concat [p@(Fix P.Wildcard), Fix (P.MapPattern ks vs Nothing _ o)] c =
      Fix (P.MapPattern ks vs (Just p) c $ Fix $ P.Pattern (Left $ P.Symbol sym) Nothing [p, o])
    mapPattern sym Unit [] c = Fix (P.MapPattern [] [] Nothing c $ Fix $ P.Pattern (Left $ P.Symbol sym) Nothing [])
    mapPattern sym Element [k,v] c = Fix (P.MapPattern [k] [v] Nothing c $ Fix $ P.Pattern (Left $ P.Symbol sym) Nothing [k,v])
    mapPattern _ Concat [_, Fix (P.MapPattern _ _ (Just _) _ _)] _ = error "unsupported map pattern"
    mapPattern _ Concat [Fix (P.MapPattern _ _ (Just _) _ _), _] _ = error "unsupported map pattern"
    mapPattern _ Concat [_, Fix (P.ListPattern _ _ _ _ _)] _ = error "unsupported map pattern"
    mapPattern _ Concat [Fix (P.ListPattern _ _ _ _ _), _] _ = error "unsupported map pattern"
    mapPattern _ Concat [_, Fix (P.SetPattern _ _ _ _)] _ = error "unsupported map pattern"
    mapPattern _ Concat [Fix (P.SetPattern _ _ _ _), _] _ = error "unsupported map pattern"
    mapPattern _ Concat [Fix (P.As _ _ _), _] _ = error "unsupported map pattern"
    mapPattern _ Concat [_, Fix (P.As _ _ _)] _ = error "unsupported map pattern"
    mapPattern _ Concat [Fix (P.Pattern _ _ _), _] _ = error "unsupported map pattern"
    mapPattern _ Concat [_, Fix (P.Pattern _ _ _)] _ = error "unsupported map pattern"
    mapPattern _ Concat [Fix P.Wildcard, _] _ = error "unsupported map pattern"
    mapPattern _ Concat [Fix (P.Variable _ _), _] _ = error "unsupported map pattern"
    mapPattern _ Concat [] _ = error "unsupported map pattern"
    mapPattern _ Concat (_:[]) _ = error "unsupported map pattern"
    mapPattern _ Concat (_:_:_:_) _ = error "unsupported map pattern"
    mapPattern _ Unit (_:_) _ = error "unsupported map pattern"
    mapPattern _ Element [] _ = error "unsupported map pattern"
    mapPattern _ Element (_:[]) _ = error "unsupported map pattern"
    mapPattern _ Element (_:_:_:_) _ = error "unsupported map pattern"
    setPattern :: SymbolOrAlias Object
               -> CollectionCons
               -> [Fix P.Pattern]
               -> SymbolOrAlias Object
               -> Fix P.Pattern
    setPattern sym Concat [Fix (P.SetPattern ks Nothing _ o), Fix (P.SetPattern ks' frame _ o')] c =
      Fix (P.SetPattern (ks ++ ks') frame c $ Fix $ P.Pattern (Left $ P.Symbol sym) Nothing [o, o'])
    setPattern sym Concat [Fix (P.SetPattern ks frame _ o), Fix (P.SetPattern ks' Nothing _ o')] c =
      Fix (P.SetPattern (ks ++ ks') frame c $ Fix $ P.Pattern (Left $ P.Symbol sym) Nothing [o, o'])
    setPattern sym Concat [Fix (P.SetPattern ks Nothing _ o), p@(Fix (P.Variable _ _))] c =
      Fix (P.SetPattern ks (Just p) c $ Fix $ P.Pattern (Left $ P.Symbol sym) Nothing [o, p])
    setPattern sym Concat [Fix (P.SetPattern ks Nothing _ o), p@(Fix P.Wildcard)] c =
      Fix (P.SetPattern ks (Just p) c $ Fix $ P.Pattern (Left $ P.Symbol sym) Nothing [o, p])
    setPattern sym Concat [p@(Fix (P.Variable _ _)), Fix (P.SetPattern ks Nothing _ o)] c =
      Fix (P.SetPattern ks (Just p) c $ Fix $ P.Pattern (Left $ P.Symbol sym) Nothing [p, o])
    setPattern sym Concat [p@(Fix P.Wildcard), Fix (P.SetPattern ks Nothing _ o)] c =
      Fix (P.SetPattern ks (Just p) c $ Fix $ P.Pattern (Left $ P.Symbol sym) Nothing [p, o])
    setPattern sym Unit [] c = Fix (P.SetPattern [] Nothing c $ Fix $ P.Pattern (Left $ P.Symbol sym) Nothing [])
    setPattern sym Element [e] c = Fix (P.SetPattern [e] Nothing c $ Fix $ P.Pattern (Left $ P.Symbol sym) Nothing [e])
    setPattern _ Concat [_, Fix (P.SetPattern _ (Just _) _ _)] _ = error "unsupported set pattern"
    setPattern _ Concat [Fix (P.SetPattern _ (Just _) _ _), _] _ = error "unsupported set pattern"
    setPattern _ Concat [_, Fix (P.MapPattern _ _ _ _ _)] _ = error "unsupported set pattern"
    setPattern _ Concat [Fix (P.MapPattern _ _ _ _ _), _] _ = error "unsupported set pattern"
    setPattern _ Concat [_, Fix (P.ListPattern _ _ _ _ _)] _ = error "unsupported set pattern"
    setPattern _ Concat [Fix (P.ListPattern _ _ _ _ _), _] _ = error "unsupported set pattern"
    setPattern _ Concat [Fix (P.As _ _ _), _] _ = error "unsupported set pattern"
    setPattern _ Concat [_, Fix (P.As _ _ _)] _ = error "unsupported set pattern"
    setPattern _ Concat [Fix (P.Pattern _ _ _), _] _ = error "unsupported set pattern"
    setPattern _ Concat [_, Fix (P.Pattern _ _ _)] _ = error "unsupported set pattern"
    setPattern _ Concat [Fix P.Wildcard, _] _ = error "unsupported set pattern"
    setPattern _ Concat [Fix (P.Variable _ _), _] _ = error "unsupported set pattern"
    setPattern _ Concat [] _ = error "unsupported set pattern"
    setPattern _ Concat (_:[]) _ = error "unsupported set pattern"
    setPattern _ Concat (_:_:_:_) _ = error "unsupported set pattern"
    setPattern _ Unit (_:_) _ = error "unsupported set pattern"
    setPattern _ Element [] _ = error "unsupported set pattern"
    setPattern _ Element (_:_:_) _ = error "unsupported set pattern"

    getSym :: Text -> [SymbolOrAlias Object] -> SymbolOrAlias Object
    getSym hookAtt syms = head $ filter (isHook hookAtt) syms
    isHook :: Text -> SymbolOrAlias Object -> Bool
    isHook hookAtt sym =
      let att = getHook $ hook $ parseAtt $ symAttributes tools sym
      in att == Just hookAtt

genVars :: CommonKorePattern -> [String]
genVars = para (unifiedPatternRAlgebra rAlgebra rAlgebra)
  where
    rAlgebra :: Pattern lvl Variable (CommonKorePattern,
                                     [String])
             -> [String]
    rAlgebra (VariablePattern (Variable (Id name _) _)) = [unpack name]
    rAlgebra (AndPattern (And _ (_, p₀) (_, p₁)))         = p₀ ++ p₁
    rAlgebra (ApplicationPattern (Application _ ps))      = mconcat $ map snd ps
    rAlgebra (CeilPattern (Ceil _ _ (_, p)))              = p
    rAlgebra (EqualsPattern (Equals _ _ (_, p₀) (_, p₁))) = p₀ ++ p₁
    rAlgebra (ExistsPattern (Exists _ _ (_, p)))          = p
    rAlgebra (FloorPattern (Floor _ _ (_, p)))            = p
    rAlgebra (ForallPattern (Forall _ _ (_, p)))          = p
    rAlgebra (IffPattern (Iff _ (_, p₀) (_, p₁)))         = p₀ ++ p₁
    rAlgebra (ImpliesPattern (Implies _ (_, p₀) (_, p₁))) = p₀ ++ p₁
    rAlgebra (InPattern (In _ _ (_, p₀) (_, p₁)))         = p₀ ++ p₁
    rAlgebra (NextPattern (Next _ (_, p)))                = p
    rAlgebra (NotPattern (Not _ (_, p)))                  = p
    rAlgebra (OrPattern (Or _ (_, p₀) (_, p₁)))           = p₀ ++ p₁
    rAlgebra _                                            = []

metaLookup :: (P.Constructor P.BoundPattern -> Maybe [P.Metadata P.BoundPattern])
           -> P.Constructor P.BoundPattern
           -> Maybe [P.Metadata P.BoundPattern]
metaLookup f c@(P.SymbolConstructor (P.Symbol _)) = f c
metaLookup _ (P.LiteralConstructor (P.Literal _)) = Just []
metaLookup f (P.List c i) = Just $ replicate i $ head $ fromJust $ f $ P.SymbolConstructor $ P.Symbol c
metaLookup _ P.Empty = Just []
metaLookup _ (P.NonEmpty (P.Ignoring m)) = Just [m]
metaLookup f (P.HasKey isSet e (P.Ignoring m) _) =
  let metas = fromJust $ f $ P.SymbolConstructor $ P.Symbol e
  in if isSet then Just [m, m] else Just [head $ tail $ metas, m, m]
metaLookup _ (P.HasNoKey (P.Ignoring m) _) = Just [m]

defaultMetadata :: Sort Object -> P.Metadata P.BoundPattern
defaultMetadata sort = P.Metadata 1 (const []) (const []) sort $ metaLookup $ const Nothing

genMetadatas :: SymLib -> KoreIndexedModule Attributes -> Map.Map (Sort Object) (P.Metadata P.BoundPattern)
genMetadatas syms@(SymLib symbols sorts allOverloads) indexedMod =
  Map.mapMaybeWithKey genMetadata sorts
  where
    genMetadata :: Sort Object -> [SymbolOrAlias Object] -> Maybe (P.Metadata P.BoundPattern)
    genMetadata sort@(SortActualSort _) constructors =
      let att = parseAtt $ sortAttributes (extractMetadataTools indexedMod) sort
          hookAtt = getHook $ hook att
          isInt = case hookAtt of
            Just "BOOL.Bool" -> True
            Just "MINT.MInt" -> True
            _                -> False
      in if isInt then
        let tools = extractMetadataTools indexedMod
            bw = bitwidth tools sort
        in Just $ P.Metadata (shiftL 1 bw) (const []) (const []) sort (metaLookup $ const Nothing)
      else
        let metadatas = genMetadatas syms indexedMod
            keys = map (P.SymbolConstructor . P.Symbol) constructors
            args = map getArgs constructors
            injections = filter isInjection keys
            overloads = filter isOverload keys
            usedInjs = map (\c -> filter (isSubsort metadatas c) injections) injections
            usedOverloads = map (map (P.SymbolConstructor . P.Symbol) . (allOverloads Map.!) . (\(P.SymbolConstructor (P.Symbol s)) -> s)) overloads
            children = map (map $ (\s -> Map.findWithDefault (defaultMetadata s) s metadatas)) args
            metaMap = Map.fromList (zip keys children)
            injMap = Map.fromList (zip injections usedInjs)
            overloadMap = Map.fromList (zip overloads usedOverloads)
            overloadInjMap = Map.mapWithKey (\k -> (map $ injectionForOverload k)) overloadMap
            trueInjMap = Map.union injMap overloadInjMap
        in Just $ P.Metadata (toInteger $ length constructors) (\s -> if isInjection s || isOverload s then trueInjMap Map.! s else []) (\s -> Map.findWithDefault [] s overloadMap) sort $ metaLookup $ flip Map.lookup metaMap
    genMetadata _ _ = Nothing
    getArgs :: SymbolOrAlias Object -> [Sort Object]
    getArgs sym = sel1 $ symbols Map.! sym
    isInjection :: P.Constructor P.BoundPattern -> Bool
    isInjection (P.SymbolConstructor (P.Symbol (SymbolOrAlias (Id "inj" _) _))) = True
    isInjection _ = False
    isOverload :: P.Constructor P.BoundPattern -> Bool
    isOverload (P.SymbolConstructor (P.Symbol s)) = Map.member s allOverloads
    isOverload _ = False
    isSubsort :: Map.Map (Sort Object) (P.Metadata P.BoundPattern) -> P.Constructor P.BoundPattern -> P.Constructor P.BoundPattern -> Bool
    isSubsort metas (P.SymbolConstructor (P.Symbol (SymbolOrAlias name [b,_]))) (P.SymbolConstructor (P.Symbol (SymbolOrAlias _ [a,_]))) =
      let (P.Metadata _ _ _ _ childMeta) = Map.findWithDefault (defaultMetadata b) b metas
          child = P.Symbol (SymbolOrAlias name [a,b])
      in isJust $ childMeta $ (P.SymbolConstructor child)
    isSubsort _ _ _ = error "invalid injection"
    injectionForOverload :: P.Constructor P.BoundPattern -> P.Constructor P.BoundPattern -> P.Constructor P.BoundPattern
    injectionForOverload (P.SymbolConstructor (P.Symbol g)) (P.SymbolConstructor (P.Symbol l)) = P.SymbolConstructor $ P.Symbol $ SymbolOrAlias (Id "inj" AstLocationNone) [sel2 (symbols Map.! l), sel2 (symbols Map.! g)]
    injectionForOverload _ _ = error "invalid overload"

genClauseMatrix :: KoreRewrite pat
               => SymLib
               -> KoreIndexedModule Attributes
               -> [AxiomInfo pat]
               -> [Sort Object]
               -> (P.ClauseMatrix P.Pattern P.BoundPattern, P.Fringe)
genClauseMatrix symlib indexedMod axioms sorts =
  let indices = map getOrdinal axioms
      rewrites = map getRewrite axioms
      sideConditions = map getSideCondition axioms
      tools = extractMetadataTools indexedMod
      patterns = map (genPattern tools symlib) rewrites
      rhsVars = map (genVars . getRightHandSide) rewrites
      scVars = map (maybe Nothing (Just . genVars)) sideConditions
      actions = zipWith3 P.Action indices rhsVars scVars
      metas = genMetadatas symlib indexedMod
      meta = map (metas Map.!) sorts
      col = zipWith P.Column meta (transpose patterns)
  in case P.mkClauseMatrix col actions of
       Left err -> error (unpack err)
       Right m -> m

mkDecisionTree :: KoreRewrite pat
               => SymLib
               -> KoreIndexedModule Attributes
               -> [AxiomInfo pat]
               -> [Sort Object]
               -> Free P.Anchor P.Alias
mkDecisionTree symlib indexedMod axioms sorts =
  let matrix = genClauseMatrix symlib indexedMod axioms sorts
      dt = P.compilePattern matrix
  in P.shareDt dt
