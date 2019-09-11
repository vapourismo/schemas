{-# LANGUAGE AllowAmbiguousTypes   #-}
{-# LANGUAGE DeriveAnyClass        #-}
{-# LANGUAGE DeriveFunctor         #-}
{-# LANGUAGE DeriveGeneric         #-}
{-# LANGUAGE DerivingStrategies    #-}
{-# LANGUAGE DerivingVia           #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE GADTs                 #-}
{-# LANGUAGE OverloadedLabels      #-}
{-# LANGUAGE OverloadedLists       #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE RankNTypes            #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE StandaloneDeriving    #-}
{-# LANGUAGE TupleSections         #-}
{-# LANGUAGE ViewPatterns          #-}
{-# OPTIONS -Wno-name-shadowing    #-}
module Schemas.Internal where

import           Control.Alternative.Free
import           Control.Applicative      (Alternative (..))
import           Control.Lens             hiding (Empty, enum)
import           Control.Monad
import           Data.Aeson               (Value)
import qualified Data.Aeson               as A
import           Data.Aeson.Lens
import           Data.Biapplicative
import           Data.Either
import           Data.Functor.Compose
import           Data.Generics.Labels     ()
import           Data.Hashable
import           Data.HashMap.Strict      (HashMap)
import qualified Data.HashMap.Strict      as Map
import           Data.List                (find)
import           Data.List.NonEmpty       (NonEmpty (..))
import qualified Data.List.NonEmpty       as NE
import           Data.Maybe
import           Data.Scientific
import           Data.Text                (Text, pack, unpack)
import           Data.Tuple
import           Data.Vector              (Vector)
import qualified Data.Vector              as V
import           GHC.Exts                 (fromList)
import           GHC.Generics             (Generic)
import           Numeric.Natural
import           Prelude                  hiding (lookup)

-- Schemas
-- --------------------------------------------------------------------------------

data Schema
  = Empty
  | Array Schema
  | StringMap Schema
  | Enum   (NonEmpty Text)
  | Record (HashMap Text Field)
  | Union  (HashMap Text Schema)
  | Or Schema Schema
  | Prim
  deriving (Eq, Generic, Show)

instance Monoid Schema where mempty = Empty
instance Semigroup Schema where
  Empty <> x = x
  x <> Empty = x
  a <> b = Or a b

data Field = Field
  { fieldSchema :: Schema
  , isRequired  :: Maybe Bool -- ^ defaults to True
  }
  deriving (Eq, Show)

isRequiredField :: Field -> Bool
isRequiredField Field{isRequired = Just x} = x
isRequiredField _                          = True

-- Typed schemas
-- --------------------------------------------------------------------------------

-- | TypedSchema is designed to be used with higher-kinded types, Barbie style
--   Its main addition over 'Schema' is converting from a JSON 'Value'
data TypedSchemaFlex from a where
  TEnum   :: (NonEmpty (Text, a)) -> (from -> Text) -> TypedSchemaFlex from a
  TArray :: TypedSchema b -> (Vector b -> a) -> (from -> Vector b) -> TypedSchemaFlex from a
  TMap   :: TypedSchema b -> (HashMap Text b -> a) -> (from -> HashMap Text b) -> TypedSchemaFlex from a
  TOr    :: TypedSchemaFlex from a -> TypedSchemaFlex from a -> TypedSchemaFlex from a
  TEmpty :: a -> TypedSchemaFlex from a
  TPrim  :: (Value -> A.Result a) -> (from -> Value) -> TypedSchemaFlex from a
  RecordSchema :: Alt (RecordField from) a -> TypedSchemaFlex from a
  UnionSchema :: (NonEmpty (Text, TypedSchemaFlex from a)) -> (from -> Text) -> TypedSchemaFlex from a

enum :: Eq a => (a -> Text) -> (NonEmpty a) -> TypedSchema a
enum showF opts = TEnum alts (fromMaybe (error "invalid alt") . flip lookup altMap)
 where
  altMap = fmap swap $ alts --TODO fast lookup
  alts   = opts <&> \x -> (showF x, x)

stringMap :: TypedSchema a -> TypedSchema (HashMap Text a)
stringMap sc = TMap sc id id

list :: TypedSchema a -> TypedSchema [a]
list schema = TArray schema V.toList V.fromList

prim :: (A.FromJSON a, A.ToJSON a) => TypedSchema a
prim = TPrim A.fromJSON A.toJSON

instance Functor (TypedSchemaFlex from) where
  fmap = rmap

instance Profunctor TypedSchemaFlex where
    dimap _ f (TEmpty a                ) = TEmpty (f a)
    dimap g f (TOr       a    b        ) = TOr (dimap g f a) (dimap g f b)
    dimap g f (TEnum     opts fromf    ) = TEnum (second f <$> opts) (fromf . g)
    dimap g f (TArray      sc tof fromf) = TArray sc (f . tof) (fromf . g)
    dimap g f (TMap        sc tof fromf) = TMap sc (f . tof) (fromf . g)
    dimap g f (TPrim          tof fromf) = TPrim (fmap f . tof) (fromf . g)
    dimap g f (RecordSchema sc) = RecordSchema (f <$> hoistAlt (dimap g id) sc)
    dimap g f (UnionSchema tags getTag ) = UnionSchema (second (dimap g f) <$> tags) (getTag . g)

instance Monoid a => Monoid (TypedSchemaFlex f a) where
  mempty = TEmpty mempty

instance Semigroup a => Semigroup (TypedSchemaFlex f a) where
  TEmpty a <> TEmpty b = TEmpty (a <> b)
  TEmpty{} <> x = x
  x <> TEmpty{} = x
  a <> b = TOr a b

type TypedSchema a = TypedSchemaFlex a a

-- --------------------------------------------------------------------------------
-- Applicative records

data RecordField from a where
  RequiredAp :: Text -> TypedSchemaFlex from a -> RecordField from a
  OptionalAp :: Text -> TypedSchemaFlex a a -> (from -> Maybe a) -> (Maybe a -> r) -> RecordField from r

instance Profunctor RecordField where
  dimap f g (RequiredAp name sc) = RequiredAp name (dimap f g sc)
  dimap f g (OptionalAp name sc from to) = OptionalAp name sc (from . f) (g . to)

fieldName :: RecordField from a -> Text
fieldName (RequiredAp x _) = x
fieldName (OptionalAp x _ _ _) = x

-- | Define a record schema using applicative syntax
record :: Alt (RecordField a) a -> TypedSchema a
record = RecordSchema

field :: HasSchema a => Text -> (from -> a) -> Alt (RecordField from) a
field = fieldWith schema

fieldWith :: TypedSchema a -> Text -> (from -> a) -> Alt (RecordField from) a
fieldWith schema n get = liftAlt (RequiredAp n (dimap get id schema))

optField :: forall a from. HasSchema a => Text -> (from -> Maybe a) -> Alt (RecordField from) (Maybe a)
optField = optFieldWith schema

optFieldWith :: forall a from. TypedSchema a -> Text -> (from -> Maybe a) -> Alt (RecordField from) (Maybe a)
optFieldWith schema n get = liftAlt (OptionalAp n schema get id)

-- --------------------------------------------------------------------------------
-- Typed Unions

union :: (NonEmpty (Text, TypedSchema a, a -> Bool)) -> TypedSchema a
union args = UnionSchema constructors fromF
 where
  constructors = args <&> \(c, sc, _) -> (c, sc)
  fromF x = maybe (error $ "invalid constructor") (view _1)
    $ find (\(_, _, p) -> p x) args

data UnionTag from where
  UnionTag :: Text -> Prism' from b -> TypedSchema b -> UnionTag from

alt :: HasSchema a => Text -> Prism' from a -> UnionTag from
alt n p = UnionTag n p schema

union' :: (NonEmpty (UnionTag from)) -> TypedSchema from
union' args = union $ args <&> \(UnionTag c p sc) ->
    withPrism p $ \t f ->
      (c, dimap (either (error "impossible") id . f) t sc, isRight . f)

-- HasSchema class and instances
-- -----------------------------------------------------------------------------------

class HasSchema a where
  schema :: TypedSchema a

instance HasSchema () where
  schema = mempty

instance HasSchema Bool where
  schema = prim

instance HasSchema Double where
  schema = prim

instance HasSchema Scientific where
  schema = prim

instance HasSchema Int where
  schema = prim

instance HasSchema Integer where
  schema = prim

instance HasSchema Natural where
  schema = prim

instance {-# OVERLAPPING #-} HasSchema String where
  schema = prim

instance HasSchema Text where
  schema = prim

instance {-# OVERLAPPABLE #-} HasSchema a => HasSchema [a] where
  schema = TArray schema V.toList V.fromList

instance HasSchema a => HasSchema (Vector a) where
  schema = TArray schema id id

instance  HasSchema a => HasSchema (NonEmpty a) where
  schema = TArray schema (NE.fromList . V.toList) (V.fromList . NE.toList)

instance HasSchema Field where
  schema = record $ Field <$> field "schema" fieldSchema <*> optField "field'" isRequired

instance HasSchema a => HasSchema (Identity a) where
  schema = dimap runIdentity Identity schema

instance HasSchema Schema where
  schema = union'
    [ alt "StringMap" #_StringMap
    , alt "Array" #_Array
    , alt "Enum" #_Enum
    , alt "Record" #_Record
    , alt "Union" #_Union
    , alt "Empty" #_Empty
    , alt "Or" #_Or
    , alt "Prim" #_Prim
    ]

instance HasSchema Value where
  schema = prim

instance (HasSchema a, HasSchema b) => HasSchema (a,b) where
  schema = record $ (,) <$> field "$1" fst <*> field "$2" snd

instance (HasSchema a, HasSchema b, HasSchema c) => HasSchema (a,b,c) where
  schema = record $ (,,) <$> field "$1" (view _1) <*> field "$2" (view _2) <*> field "$3" (view _3)

instance (Eq key, Hashable key, HasSchema a, Key key) => HasSchema (HashMap key a) where
  schema = dimap toKeyed fromKeyed $ stringMap schema
    where
      fromKeyed :: HashMap Text a -> HashMap key a
      fromKeyed = Map.fromList . map (first $ view (from $ keyIso @key)) . Map.toList
      toKeyed :: HashMap key a -> HashMap Text a
      toKeyed = Map.fromList . map (first $ view (keyIso @key)) . Map.toList

class Key a where
  keyIso :: Iso' a Text

instance Key String where
  keyIso = iso pack unpack

instance Key Text where
  keyIso = id
-- --------------------------------------------------------------------------------
-- Finite schemas

-- | Ensure that a 'Schema' is finite by enforcing a max depth.
--   The result is guaranteed to be a supertype of the input.
finite :: Natural -> Schema -> Schema
finite = go
 where
  go :: Natural -> Schema -> Schema
  go 0 _ = Empty
  go d (Record    opts) = Record $ fromList $ mapMaybe
    (\(fieldname, Field sc isOptional) -> case go (max 0 (pred d)) sc of
      Empty -> Nothing
      sc'   -> Just (fieldname, Field sc' isOptional)
    )
    (Map.toList opts)
  go d (Union     opts) = Union (fmap (go (max 0 (pred d))) opts)
  go d (Array     sc  ) = Array (go (max 0 (pred d)) sc)
  go d (StringMap sc  ) = StringMap (go (max 0 (pred d)) sc)
  go d (Or a b        ) = Or (finite (d - 1) a) (finite (d - 1) b)
  go _ other            = other

-- | Ensure that a 'Value' is finite by enforcing a max depth in a schema preserving way
finiteValue :: Natural -> Schema -> Value -> Value
finiteValue d sc
  | Just cast <- sc `isSubtypeOf` finite d sc = cast
  | otherwise = error "bug in isSubtypeOf"

-- --------------------------------------------------------------------------------
-- Schema extraction from a TypedSchema

-- | Extract an untyped schema that can be serialized
extractSchema :: TypedSchemaFlex from a -> Schema
extractSchema TPrim{}          = Prim
extractSchema (TOr a b)        = Or (extractSchema a) (extractSchema b)
extractSchema TEmpty{}         = Empty
extractSchema (TEnum opts  _)  = Enum (fst <$> opts)
extractSchema (TArray sc _ _)  = Array $ extractSchema sc
extractSchema (TMap sc _ _)    = StringMap $ extractSchema sc
extractSchema (RecordSchema rs) = foldMap (Record . fromList) $ runAlt_ ((:[]) . (:[]) . extractField) rs
  where
    extractField :: RecordField from a -> (Text, Field)
    extractField (RequiredAp n sc) = (n,) . (`Field` Nothing) $ extractSchema sc
    extractField (OptionalAp n sc _ _) = (n,) . (`Field` Just False) $ extractSchema sc
extractSchema (UnionSchema scs _getTag) =
  Union . Map.fromList . NE.toList $ fmap (\(n, sc) -> (n, extractSchema sc)) scs

theSchema :: forall a . HasSchema a => Schema
theSchema = extractSchema (schema @a)

-- ---------------------------------------------------------------------------------------
-- Encoding

-- | Given a value and its typed schema, produce a JSON record using the 'RecordField's
encodeWith :: TypedSchemaFlex from a -> from -> Value
encodeWith (TOr a b) x = encodeAlternatives [encodeWith a x, encodeWith b x]
encodeWith (TEnum   _ fromf        ) b = A.String (fromf b)
encodeWith (TPrim   _ fromf        ) b = fromf b
encodeWith (TEmpty _               ) _ = A.object []
encodeWith (TArray      sc  _ fromf) b = A.Array (encodeWith sc <$> fromf b)
encodeWith (TMap        sc  _ fromf) b = A.Object (encodeWith sc <$> fromf b)
encodeWith (RecordSchema rec) x = encodeAlternatives $ fmap (A.Object . fromList) fields
            where
                fields = runAlt_ (maybe [[]] ((: []) . (: [])) . extractFieldAp x) rec

                extractFieldAp b (RequiredAp n sc  ) = Just (n, encodeWith sc b)
                extractFieldAp b (OptionalAp n sc from _) = (n,) . encodeWith sc <$> from b

encodeWith (UnionSchema [(_, sc)] _    ) x = encodeWith sc x
encodeWith (UnionSchema opts      fromF) x = case lookup tag opts of
            Nothing       -> error $ "Unknown tag: " <> show tag
            Just TEmpty{} -> A.String tag
            Just sc       -> A.object [tag A..= encodeWith sc x]
            where tag = fromF x

encodeAlternatives :: [Value] -> Value
encodeAlternatives [] = error "empty"
encodeAlternatives [x] = x
encodeAlternatives (x:xx) = A.object ["L" A..= x, "R" A..= encodeAlternatives xx]

-- | encode using the default schema
encode :: HasSchema a => a -> Value
encode = encodeWith schema

encodeToWith :: TypedSchema a -> Schema -> Maybe (a -> Value)
encodeToWith sc target = case extractSchema sc `isSubtypeOf` target of
  Just cast -> Just $ cast . encodeWith sc
  Nothing   -> Nothing

encodeTo :: HasSchema a => Schema -> Maybe (a -> Value)
encodeTo = encodeToWith schema

-- | Encode a value into a finite representation by enforcing a max depth
finiteEncode :: forall a. HasSchema a => Natural -> a -> Value
finiteEncode d = finiteValue d (theSchema @a) . encode

-- --------------------------------------------------------------------------
-- Decoding

-- TODO extract context out of DecodeError
data DecodeError
  = InvalidRecordField { name :: Text, context :: [Text]}
  | MissingRecordField { name :: Text, context :: [Text]}
  | InvalidEnumValue { given :: Text, options :: NonEmpty Text, context :: [Text]}
  | InvalidConstructor { name :: Text, context :: [Text]}
  | InvalidUnionType { contents :: Value, context :: [Text]}
  | SchemaMismatch {context :: [Text]}
  | InvalidAlt {context :: [Text], path :: Path}
  | PrimError {context :: [Text], primError :: String}
  deriving (Eq, Show)

-- | Given a JSON 'Value' and a typed schema, extract a Haskell value
decodeWith :: TypedSchemaFlex from a -> Value -> Either DecodeError a
decodeWith = go []
 where
  go :: [Text] -> TypedSchemaFlex from a -> Value -> Either DecodeError a
  go ctx (TEnum opts _) (A.String x) =
    maybe (Left $ InvalidEnumValue x (fst <$> opts) ctx) pure $ lookup x opts
  go ctx (TArray sc tof _) (A.Array x) =
    tof <$> traverse (go ("[]" : ctx) sc) x
  go ctx (TMap sc tof _) (A.Object x) = tof <$> traverse (go ("[]" : ctx) sc) x
  go _tx (TEmpty a) _ = pure a
  go ctx (RecordSchema rec) o@A.Object{}
    | (A.Object fields, encodedPath) <- decodeAlternatives o = fromMaybe
      (Left $ InvalidAlt ctx encodedPath)
      (selectPath encodedPath (getCompose $ runAlt (Compose . (: []) . f fields) rec))
   where
    f :: A.Object -> RecordField from a -> Either DecodeError a
    f fields (RequiredAp n sc) = doRequiredField ctx n sc fields
    f fields (OptionalAp n sc _ to) = case Map.lookup n fields of
        Just v  -> to . Just <$> go (n : ctx) sc v
        Nothing -> pure $ to Nothing

  go _tx (UnionSchema opts _) (A.String n)
    | Just (TEmpty a) <- lookup n opts = pure a
  go ctx (UnionSchema opts _) it@(A.Object x) = case Map.toList x of
    [(n, v)] -> case lookup n opts of
      Just sc -> go (n : ctx) sc v
      Nothing -> Left $ InvalidConstructor n ctx
    _ -> Left $ InvalidUnionType it ctx
  go ctx (TOr a b) (A.Object x) = do
    let l = Map.lookup "L" x <&> go ("L":ctx) a
    let r = Map.lookup "R" x <&> go ("R":ctx) b
    fromMaybe (Left $ SchemaMismatch ctx) $ l <|> r
  go ctx (TPrim tof _) x = case tof x of
    A.Error e   -> Left (PrimError ctx e)
    A.Success a -> pure a
  go ctx _ _ = Left $ SchemaMismatch ctx

  doRequiredField
    :: [Text]
    -> Text
    -> TypedSchemaFlex from b
    -> HashMap Text Value
    -> Either DecodeError b
  doRequiredField ctx n sc fields = case Map.lookup n fields of
    Just v  -> go (n : ctx) sc v
    Nothing -> case sc of
      TArray _ tof' _ -> pure $ tof' []
      _               -> Left $ MissingRecordField n ctx

decode :: HasSchema a => Value -> Either DecodeError a
decode = decodeWith schema

decodeFromWith :: TypedSchema a -> Schema -> Maybe (Value -> Either DecodeError a)
decodeFromWith sc source = case source `isSubtypeOf` extractSchema sc of
  Just cast -> Just $ decodeWith sc . cast
  Nothing -> Nothing

decodeFrom :: HasSchema a => Schema -> Maybe (Value -> Either DecodeError a)
decodeFrom = decodeFromWith schema

type Path = [Bool]

decodeAlternatives :: Value -> (Value, Path)
decodeAlternatives (A.Object x)
  | Just v <- Map.lookup "L" x = (v, [True])
  | Just v <- Map.lookup "R" x = (False :) <$> decodeAlternatives v
  | otherwise                  = (A.Object x, [])
decodeAlternatives x = (x,[])

selectPath :: Path -> [a] -> Maybe a
selectPath (True : _) (x : _)  = Just x
selectPath (False:rest) (_:xx) = selectPath rest xx
selectPath [] [x]              = Just x
selectPath _ _                 = Nothing

-- ------------------------------------------------------------------------------------------------------
-- Subtype relation

-- | @sub isSubtypeOf sup@ returns a witness that @sub@ is a subtype of @sup@, i.e. a cast function @sub -> sup@
--
-- > Array Bool `isSubtypeOf` Bool
--   Just <function>
-- > Record [("a", Bool)] `isSubtypeOf` Record [("a", Number)]
--   Nothing
isSubtypeOf :: Schema -> Schema -> Maybe (Value -> Value)
isSubtypeOf sub sup = go sup sub
    where
        nil = A.Object $ fromList []
        go Empty         _         = pure $ const nil
        go (Array     _) Empty     = pure $ const (A.Array [])
        go (Union     _) Empty     = pure $ const nil
        go (Record    _) Empty     = pure $ const nil
        go (StringMap _) Empty     = pure $ const nil
        go Or{}          Empty     = pure $ const nil
        go (Array a)     (Array b) = do
            f <- go a b
            pure $ over (_Array . traverse) f
        go (StringMap a) (StringMap b) = do
            f <- go a b
            pure $ over (_Object . traverse) f
        go a (Array b) | a == b                               = Just (A.Array . fromList . (: []))
        go (Enum opts) (Enum opts') | all (`elem` opts') opts = Just id
        go (Union opts) (Union opts')                         = do
            ff <- forM (Map.toList opts) $ \(n, sc) -> do
                sc' <- Map.lookup n opts'
                f   <- go sc sc'
                return $ over (_Object . ix n) f
            return (foldr (.) id ff)
        go (Record opts) (Record opts') = do
            forM_ (Map.toList opts)
                $ \(n, f@(Field _ _)) -> guard $ not (isRequiredField f) || Map.member n opts'
            ff <- forM (Map.toList opts') $ \(n', f'@(Field sc' _)) -> do
                case Map.lookup n' opts of
                    Nothing -> do
                        Just $ over (_Object) (Map.delete n')
                    Just f@(Field sc _) -> do
                        guard (not (isRequiredField f) || isRequiredField f')
                        witness <- go sc sc'
                        Just $ over (_Object . ix n') witness
            return (foldr (.) id ff)
        go a (Or b c) =
            (go a b <&> \f -> fromMaybe (error "cannot upcast an alternative: missing L value")
                    . preview (_Object . ix "L" . to f)
                )
                <|> (go a c <&> \f ->
                        fromMaybe (error "cannot upcast an alternative: missing R value")
                            . preview (_Object . ix "R" . to f)
                    )
        go (Or a b) c =
            (go a c <&> ((A.object . (: []) . ("L" A..=)) .))
                <|> (go b c <&> ((A.object . (: []) . ("R" A..=)) .))
        go a b | a == b = pure id
        go _ _          = Nothing

-- | Returns 'Nothing' if 'sub' is not a subtype of 'sup'
coerce :: forall sub sup . (HasSchema sub, HasSchema sup) => Value -> Maybe Value
coerce = case isSubtypeOf (theSchema @sub) (theSchema @sup) of
  Just cast -> Just . cast
  Nothing   -> const Nothing

-- ----------------------------------------------
-- Utils

-- | Generalized lookup for Foldables
lookup :: (Eq a, Foldable f) => a -> f (a,b) -> Maybe b
lookup a = fmap snd . find ((== a) . fst)

runAlt_ :: (Alternative g, Monoid m) => (forall a. f a -> g m) -> Alt f b -> g m
runAlt_ f = fmap getConst . getCompose . runAlt (Compose . fmap Const . f)

-- >>> data Person = Person {married :: Bool, age :: Int}
-- >>> runAlt_  (\x -> [[fieldName x]]) (Person <$> (field "married" married <|> field "foo" married) <*> (field "age" age <|> pure 0))
-- [["married","age"],["married"],["foo","age"],["foo"]]

-- ----------------------------------------------
-- Examples

-- The Schema schema is recursive and cannot be serialized unless we use finiteEncode
-- >>> import Text.Pretty.Simple
-- >>> pPrintNoColor $ finite 2 (theSchema @Schema)
-- Union
--     ( fromList
--         [
--             ( "String"
--             , Empty
--             )
--         ,
--             ( "Empty"
--             , Empty
--             )
--         ,
--             ( "Union"
--             , StringMap Empty
--             )
--         ,
--             ( "StringMap"
--             , Union
--                 ( fromList
--                     [
--                         ( "String"
--                         , Empty
--                         )
--                     ,
--                         ( "Empty"
--                         , Empty
--                         )
--                     ,
--                         ( "Union"
--                         , Empty
--                         )
--                     ,
--                         ( "StringMap"
--                         , Empty
--                         )
--                     ,
--                         ( "Array"
--                         , Empty
--                         )
--                     ,
--                         ( "Record"
--                         , Empty
--                         )
--                     ,
--                         ( "Enum"
--                         , Empty
--                         )
--                     ,
--                         ( "Number"
--                         , Empty
--                         )
--                     ,
--                         ( "Bool"
--                         , Empty
--                         )
--                     ]
--                 )
--             )
--         ,
--             ( "Array"
--             , Union
--                 ( fromList
--                     [
--                         ( "String"
--                         , Empty
--                         )
--                     ,
--                         ( "Empty"
--                         , Empty
--                         )
--                     ,
--                         ( "Union"
--                         , Empty
--                         )
--                     ,
--                         ( "StringMap"
--                         , Empty
--                         )
--                     ,
--                         ( "Array"
--                         , Empty
--                         )
--                     ,
--                         ( "Record"
--                         , Empty
--                         )
--                     ,
--                         ( "Enum"
--                         , Empty
--                         )
--                     ,
--                         ( "Number"
--                         , Empty
--                         )
--                     ,
--                         ( "Bool"
--                         , Empty
--                         )
--                     ]
--                 )
--             )
--         ,
--             ( "Record"
--             , StringMap Empty
--             )
--         ,
--             ( "Enum"
--             , Array String
--             )
--         ,
--             ( "Number"
--             , Empty
--             )
--         ,
--             ( "Bool"
--             , Empty
--             )
--         ]
--     )

-- >>> import Data.Aeson.Encode.Pretty
-- >>> import qualified Data.ByteString.Lazy.Char8 as B
-- >>> B.putStrLn $ encodePretty $ finiteEncode 4 (theSchema @Schema)
-- {
--     "Union": {
--         "String": "Empty",
--         "Empty": "Empty",
--         "Union": {
--             "StringMap": {
--                 "Union": {}
--             }
--         },
--         "StringMap": {
--             "Union": {
--                 "String": {},
--                 "Empty": {},
--                 "Union": {},
--                 "StringMap": {},
--                 "Array": {},
--                 "Record": {},
--                 "Enum": {},
--                 "Number": {},
--                 "Bool": {}
--             }
--         },
--         "Array": {
--             "Union": {
--                 "String": {},
--                 "Empty": {},
--                 "Union": {},
--                 "StringMap": {},
--                 "Array": {},
--                 "Record": {},
--                 "Enum": {},
--                 "Number": {},
--                 "Bool": {}
--             }
--         },
--         "Record": {
--             "StringMap": {
--                 "Record": {}
--             }
--         },
--         "Enum": {
--             "Array": "String"
--         },
--         "Number": "Empty",
--         "Bool": "Empty"
--     }
-- }

-- Deserializing a value V of a recursive schema S is not supported,
-- because S is not a subtype of the truncated schema finite(S)

-- >>> isJust $ finite 10 (theSchema @Schema) `isSubtypeOf` theSchema @Schema
-- True
-- >>> isJust $ theSchema @Schema `isSubtypeOf` finite 10 (theSchema @Schema)
-- False

