{-# LANGUAGE CPP                  #-}
{-# LANGUAGE DefaultSignatures    #-}
{-# LANGUAGE DeriveDataTypeable   #-}
{-# LANGUAGE DeriveFoldable       #-}
{-# LANGUAGE DeriveFunctor        #-}
{-# LANGUAGE DeriveTraversable    #-}
{-# LANGUAGE FlexibleInstances    #-}
{-# LANGUAGE KindSignatures       #-}
{-# LANGUAGE OverloadedStrings    #-}
{-# LANGUAGE PolyKinds            #-}
{-# LANGUAGE ScopedTypeVariables  #-}
{-# LANGUAGE TypeSynonymInstances #-}
-- |
-- Convert Haskell values to and from HTTP API data
-- such as URL pieces, headers and query parameters.
module Web.Internal.HttpApiData where

import           Prelude                      ()
import           Prelude.Compat

import           Control.Applicative          (Const(Const), (<|>))
import           Control.Arrow                ((&&&))
import           Control.Monad                (when)
import qualified Data.Attoparsec.ByteString   as AttoB
import qualified Data.Attoparsec.Text         as Atto
import qualified Data.Attoparsec.Time         as Atto
import           Data.Bifunctor               (first)
import           Data.ByteString              (ByteString)
import qualified Data.ByteString.Builder      as BS
import qualified Data.ByteString.Lazy         as LBS
import           Data.Coerce                  (coerce)
import           Data.Data                    (Data)
import qualified Data.Fixed                   as F
import           Data.Functor (void)
import           Data.Functor.Identity        (Identity(Identity))
import           Data.Int                     (Int16, Int32, Int64, Int8)
import           Data.Monoid                  (All (..), Any (..), Dual (..),
                                               First (..), Last (..),
                                               Product (..), Sum (..))
import qualified Data.Semigroup               as Semi
import           Data.Tagged                  (Tagged (..))
import           Data.Text                    (Text)
import qualified Data.Text                    as T
import           Data.Text.Encoding           (decodeUtf8', decodeUtf8With,
                                               encodeUtf8)
import           Data.Text.Encoding.Error     (lenientDecode)
import qualified Data.Text.Lazy               as L
import           Data.Text.Read               (Reader)
import           Data.Time.Compat             (Day, FormatTime, LocalTime,
                                               NominalDiffTime, TimeOfDay,
                                               UTCTime, ZonedTime, formatTime,
                                               DayOfWeek (..),
                                               nominalDiffTimeToSeconds,
                                               secondsToNominalDiffTime)
import           Data.Time.Format.Compat      (defaultTimeLocale,
                                               iso8601DateFormat)
import           Data.Time.Calendar.Month.Compat (Month)
import           Data.Time.Calendar.Quarter.Compat (Quarter, QuarterOfYear (..),
                                               toYearQuarter)
import           Data.Typeable                (Typeable)
import qualified Data.UUID.Types              as UUID
import           Data.Version                 (Version, showVersion)
import           Data.Void                    (Void, absurd)
import           Data.Word                    (Word16, Word32, Word64, Word8)
import qualified Network.HTTP.Types           as H
import           Numeric.Natural              (Natural)
import           Text.Read                    (readMaybe)
import           Web.Cookie                   (SetCookie, parseSetCookie,
                                               renderSetCookie)

#if MIN_VERSION_base(4,9,0)
import Data.Kind (Type)
#else
#define Type *
#endif

#if USE_TEXT_SHOW
import           TextShow                     (TextShow, showt)
#endif

-- $setup
-- >>> import Data.Time.Compat

-- | Convert value to HTTP API data.
--
-- __WARNING__: Do not derive this using @DeriveAnyClass@ as the generated
-- instance will loop indefinitely.
class ToHttpApiData a where
  {-# MINIMAL toUrlPiece | toQueryParam #-}
  -- | Convert to URL path piece.
  toUrlPiece :: a -> Text
  toUrlPiece = toQueryParam

  -- | Convert to a URL path piece, making sure to encode any special chars.
  -- The default definition uses 'H.encodePathSegmentsRelative',
  -- but this may be overriden with a more efficient version.
  toEncodedUrlPiece :: a -> BS.Builder
  toEncodedUrlPiece = H.encodePathSegmentsRelative . (:[]) . toUrlPiece

  -- | Convert to HTTP header value.
  toHeader :: a -> ByteString
  toHeader = encodeUtf8 . toUrlPiece

  -- | Convert to query param value.
  toQueryParam :: a -> Text
  toQueryParam = toUrlPiece

-- | Parse value from HTTP API data.
--
-- __WARNING__: Do not derive this using @DeriveAnyClass@ as the generated
-- instance will loop indefinitely.
class FromHttpApiData a where
  {-# MINIMAL parseUrlPiece | parseQueryParam #-}
  -- | Parse URL path piece.
  parseUrlPiece :: Atto.Parser a
  parseUrlPiece = parseQueryParam

  -- | Parse HTTP header value.
  -- FIXME: Very naive implementation.
  parseHeader :: AttoB.Parser a
  parseHeader = do
    s <- AttoB.takeByteString
    either fail pure $ do
      t <- first show $ decodeUtf8' s
      Atto.parseOnly parseUrlPiece t

  -- | Parse query param value.
  parseQueryParam :: Atto.Parser a
  parseQueryParam = parseUrlPiece

-- | Convert multiple values to a list of URL pieces.
--
-- >>> toUrlPieces [1, 2, 3] :: [Text]
-- ["1","2","3"]
toUrlPieces :: (Functor t, ToHttpApiData a) => t a -> t Text
toUrlPieces = fmap toUrlPiece

-- | Convert multiple values to a list of query parameter values.
--
-- >>> toQueryParams [fromGregorian 2015 10 03, fromGregorian 2015 12 01] :: [Text]
-- ["2015-10-03","2015-12-01"]
toQueryParams :: (Functor t, ToHttpApiData a) => t a -> t Text
toQueryParams = fmap toQueryParam

-- | Default parsing error.
defaultParseError :: Text -> Either Text a
defaultParseError input = Left ("could not parse: `" <> input <> "'")

-- | Convert @'Maybe'@ parser into @'Either' 'Text'@ parser with default error message.
parseMaybeTextData :: (Text -> Maybe a) -> (Text -> Either Text a)
parseMaybeTextData parse input =
  case parse input of
    Nothing  -> defaultParseError input
    Just val -> Right val

-- | Parse multiple query parameters.
--
-- >>> parseQueryParams ["1", "2", "3"] :: Either Text [Int]
-- Right [1,2,3]
-- >>> parseQueryParams ["64", "128", "256"] :: Either Text [Word8]
-- Left "out of bounds: `256' (should be between 0 and 255)"
parseQueryParams :: (Traversable t, FromHttpApiData a) => t Text -> Either Text (t a)
parseQueryParams = first T.pack . traverse (Atto.parseOnly (parseQueryParam <* Atto.endOfInput))

#if USE_TEXT_SHOW
-- | /Lower case/.
--
-- Convert to URL piece using @'TextShow'@ instance.
-- The result is always lower cased.
--
-- >>> showTextData True
-- "true"
--
-- This can be used as a default implementation for enumeration types:
--
-- @
-- data MyData = Foo | Bar | Baz deriving (Generic)
--
-- instance TextShow MyData where
--   showt = genericShowt
--
-- instance ToHttpApiData MyData where
--   toUrlPiece = showTextData
-- @
showTextData :: TextShow a => a -> Text
showTextData = T.toLower . showt
#else
-- | /Lower case/.
--
-- Convert to URL piece using @'Show'@ instance.
-- The result is always lower cased.
--
-- >>> showTextData True
-- "true"
--
-- This can be used as a default implementation for enumeration types:
--
-- >>> data MyData = Foo | Bar | Baz deriving (Show)
-- >>> instance ToHttpApiData MyData where toUrlPiece = showTextData
-- >>> toUrlPiece Foo
-- "foo"
showTextData :: Show a => a -> Text
showTextData = T.toLower . showt

-- | Like @'show'@, but returns @'Text'@.
showt :: Show a => a -> Text
showt = T.pack . show
#endif

-- | /Case insensitive/.
--
-- Parse given text case insensitive and then parse the rest of the input
-- using @'parseUrlPiece'@.
--
-- >>> parseUrlPieceWithPrefix "Just " "just 10" :: Either Text Int
-- Right 10
-- >>> parseUrlPieceWithPrefix "Left " "left" :: Either Text Bool
-- Left "could not parse: `left'"
--
-- This can be used to implement @'FromHttpApiData'@ for single field constructors:
--
-- >>> data Foo = Foo Int deriving (Show)
-- >>> instance FromHttpApiData Foo where parseUrlPiece s = Foo <$> parseUrlPieceWithPrefix "Foo " s
-- >>> parseUrlPiece "foo 1" :: Either Text Foo
-- Right (Foo 1)
parseUrlPieceWithPrefix :: FromHttpApiData a => Text -> Atto.Parser a
parseUrlPieceWithPrefix pattern = do
  _ <- Atto.asciiCI pattern
  parseUrlPiece

#if USE_TEXT_SHOW
-- | /Case insensitive/.
--
-- Parse values case insensitively based on @'TextShow'@ instance.
--
-- >>> parseBoundedTextData "true" :: Either Text Bool
-- Right True
-- >>> parseBoundedTextData "FALSE" :: Either Text Bool
-- Right False
--
-- This can be used as a default implementation for enumeration types:
--
-- @
-- data MyData = Foo | Bar | Baz deriving (Show, Bounded, Enum, Generic)
--
-- instance TextShow MyData where
--   showt = genericShowt
--
-- instance FromHttpApiData MyData where
--   parseUrlPiece = parseBoundedTextData
-- @
parseBoundedTextData :: (TextShow a, Bounded a, Enum a) => Text -> Either Text a
#else
-- | /Case insensitive/.
--
-- Parse values case insensitively based on @'Show'@ instance.
--
-- >>> parseBoundedTextData "true" :: Either Text Bool
-- Right True
-- >>> parseBoundedTextData "FALSE" :: Either Text Bool
-- Right False
--
-- This can be used as a default implementation for enumeration types:
--
-- >>> data MyData = Foo | Bar | Baz deriving (Show, Bounded, Enum)
-- >>> instance FromHttpApiData MyData where parseUrlPiece = parseBoundedTextData
-- >>> parseUrlPiece "foo" :: Either Text MyData
-- Right Foo
parseBoundedTextData :: (Show a, Bounded a, Enum a) => Text -> Either Text a
#endif
parseBoundedTextData = parseBoundedEnumOfI showTextData

-- | Lookup values based on a precalculated mapping of their representations.
lookupBoundedEnumOf :: (Bounded a, Enum a, Eq b) => (a -> b) -> b -> Maybe a
lookupBoundedEnumOf f = flip lookup (map (f &&& id) [minBound..maxBound])

-- | Parse values based on a precalculated mapping of their @'Text'@ representation.
--
-- >>> parseBoundedEnumOf toUrlPiece "true" :: Either Text Bool
-- Right True
--
-- For case insensitive parser see 'parseBoundedEnumOfI'.
parseBoundedEnumOf :: (Bounded a, Enum a) => (a -> Text) -> Text -> Either Text a
parseBoundedEnumOf = parseMaybeTextData . lookupBoundedEnumOf

-- | /Case insensitive/.
--
-- Parse values case insensitively based on a precalculated mapping
-- of their @'Text'@ representations.
--
-- >>> parseBoundedEnumOfI toUrlPiece "FALSE" :: Either Text Bool
-- Right False
--
-- For case sensitive parser see 'parseBoundedEnumOf'.
parseBoundedEnumOfI :: (Bounded a, Enum a) => (a -> Text) -> Text -> Either Text a
parseBoundedEnumOfI f = parseBoundedEnumOf (T.toLower . f) . T.toLower

-- | /Case insensitive/.
--
-- Parse values case insensitively based on @'ToHttpApiData'@ instance.
-- Uses @'toUrlPiece'@ to get possible values.
parseBoundedUrlPiece :: (ToHttpApiData a, Bounded a, Enum a) => String -> Atto.Parser a
parseBoundedUrlPiece typeName = foldr ((<>) . f) (fail ("Invalid " ++ typeName)) [minBound .. maxBound]
  where
    f x = x <$ Atto.asciiCI (toUrlPiece x)

-- | /Case insensitive/.
--
-- Parse values case insensitively based on @'ToHttpApiData'@ instance.
-- Uses @'toQueryParam'@ to get possible values.
parseBoundedQueryParam :: (ToHttpApiData a, Bounded a, Enum a) => Text -> Either Text a
parseBoundedQueryParam = parseBoundedEnumOfI toQueryParam

-- | Parse values based on @'ToHttpApiData'@ instance.
-- Uses @'toHeader'@ to get possible values.
parseBoundedHeader :: (ToHttpApiData a, Bounded a, Enum a) => ByteString -> Either Text a
parseBoundedHeader bs = case lookupBoundedEnumOf toHeader bs of
  Nothing -> defaultParseError $ T.pack $ show bs
  Just x  -> return x

-- | Parse URL piece using @'Read'@ instance.
--
-- Use for types which do not involve letters:
--
-- >>> readTextData "1991-06-02" :: Either Text Day
-- Right 1991-06-02
--
-- This parser is case sensitive and will not match @'showTextData'@
-- in presence of letters:
--
-- >>> readTextData (showTextData True) :: Either Text Bool
-- Left "could not parse: `true'"
--
-- See @'parseBoundedTextData'@.
readTextData :: Read a => Text -> Either Text a
readTextData = parseMaybeTextData (readMaybe . T.unpack)

-- | Run @'Reader'@ as HTTP API data parser.
runReader :: Reader a -> Text -> Either Text a
runReader reader input =
  case reader input of
    Left err          -> Left ("could not parse: `" <> input <> "' (" <> T.pack err <> ")")
    Right (x, rest)
      | T.null rest -> Right x
      | otherwise   -> defaultParseError input

-- | Run @'Reader'@ to parse bounded integral value with bounds checking.
--
-- >>> parseBounded decimal "256" :: Either Text Word8
-- Left "out of bounds: `256' (should be between 0 and 255)"
parseBounded :: forall a. (Bounded a, Integral a) => Atto.Parser Integer -> Atto.Parser a
parseBounded p = do
  n <- p
  when (n > h || n < l) $
    fail ("out of bounds: `" <> show n <> "' (should be between " <> show l <> " and " <> show h <> ")")
  pure $ fromInteger n
  where
    l = toInteger (minBound :: a)
    h = toInteger (maxBound :: a)

-- | Convert to a URL-encoded path piece using 'toUrlPiece'.
-- /Note/: this function does not check if the result contains unescaped characters!
-- This function can be used to override 'toEncodedUrlPiece' as a more efficient implementation
-- when the resulting URL piece /never/ has to be escaped.
unsafeToEncodedUrlPiece :: ToHttpApiData a => a -> BS.Builder
unsafeToEncodedUrlPiece = BS.byteString . encodeUtf8 . toUrlPiece

-- |
-- >>> toUrlPiece ()
-- "_"
instance ToHttpApiData () where
  toUrlPiece () = "_"
  toEncodedUrlPiece = unsafeToEncodedUrlPiece

instance ToHttpApiData Char where
  toUrlPiece = T.singleton

-- |
-- >>> toUrlPiece (Version [1, 2, 3] [])
-- "1.2.3"
instance ToHttpApiData Version where
  toUrlPiece = T.pack . showVersion
  toEncodedUrlPiece = unsafeToEncodedUrlPiece

instance ToHttpApiData Void    where toUrlPiece = absurd
instance ToHttpApiData Natural where toUrlPiece = showt; toEncodedUrlPiece = unsafeToEncodedUrlPiece

instance ToHttpApiData Bool     where toUrlPiece = showTextData; toEncodedUrlPiece = unsafeToEncodedUrlPiece
instance ToHttpApiData Ordering where toUrlPiece = showTextData; toEncodedUrlPiece = unsafeToEncodedUrlPiece

instance ToHttpApiData Double   where toUrlPiece = showt; toEncodedUrlPiece = unsafeToEncodedUrlPiece
instance ToHttpApiData Float    where toUrlPiece = showt; toEncodedUrlPiece = unsafeToEncodedUrlPiece
instance ToHttpApiData Int      where toUrlPiece = showt; toEncodedUrlPiece = unsafeToEncodedUrlPiece
instance ToHttpApiData Int8     where toUrlPiece = showt; toEncodedUrlPiece = unsafeToEncodedUrlPiece
instance ToHttpApiData Int16    where toUrlPiece = showt; toEncodedUrlPiece = unsafeToEncodedUrlPiece
instance ToHttpApiData Int32    where toUrlPiece = showt; toEncodedUrlPiece = unsafeToEncodedUrlPiece
instance ToHttpApiData Int64    where toUrlPiece = showt; toEncodedUrlPiece = unsafeToEncodedUrlPiece
instance ToHttpApiData Integer  where toUrlPiece = showt; toEncodedUrlPiece = unsafeToEncodedUrlPiece
instance ToHttpApiData Word     where toUrlPiece = showt; toEncodedUrlPiece = unsafeToEncodedUrlPiece
instance ToHttpApiData Word8    where toUrlPiece = showt; toEncodedUrlPiece = unsafeToEncodedUrlPiece
instance ToHttpApiData Word16   where toUrlPiece = showt; toEncodedUrlPiece = unsafeToEncodedUrlPiece
instance ToHttpApiData Word32   where toUrlPiece = showt; toEncodedUrlPiece = unsafeToEncodedUrlPiece
instance ToHttpApiData Word64   where toUrlPiece = showt; toEncodedUrlPiece = unsafeToEncodedUrlPiece

-- | Note: this instance is not polykinded
instance F.HasResolution a => ToHttpApiData (F.Fixed (a :: Type)) where toUrlPiece = showt; toEncodedUrlPiece = unsafeToEncodedUrlPiece

-- |
-- >>> toUrlPiece (fromGregorian 2015 10 03)
-- "2015-10-03"
instance ToHttpApiData Day where
  toUrlPiece = T.pack . show
  toEncodedUrlPiece = unsafeToEncodedUrlPiece

timeToUrlPiece :: FormatTime t => String -> t -> Text
timeToUrlPiece fmt = T.pack . formatTime defaultTimeLocale (iso8601DateFormat (Just fmt))

-- |
-- >>> toUrlPiece $ TimeOfDay 14 55 23.1
-- "14:55:23.1"
instance ToHttpApiData TimeOfDay where
  toUrlPiece = T.pack . formatTime defaultTimeLocale "%H:%M:%S%Q"
  toEncodedUrlPiece = unsafeToEncodedUrlPiece

-- |
-- >>> toUrlPiece $ LocalTime (fromGregorian 2015 10 03) (TimeOfDay 14 55 21.687)
-- "2015-10-03T14:55:21.687"
instance ToHttpApiData LocalTime where
  toUrlPiece = timeToUrlPiece "%H:%M:%S%Q"
  toEncodedUrlPiece = unsafeToEncodedUrlPiece

-- |
-- >>> toUrlPiece $ ZonedTime (LocalTime (fromGregorian 2015 10 03) (TimeOfDay 14 55 51.001)) utc
-- "2015-10-03T14:55:51.001+0000"
instance ToHttpApiData ZonedTime where
  toUrlPiece = timeToUrlPiece "%H:%M:%S%Q%z"
  toEncodedUrlPiece = unsafeToEncodedUrlPiece

-- |
-- >>> toUrlPiece $ UTCTime (fromGregorian 2015 10 03) 864.5
-- "2015-10-03T00:14:24.5Z"
instance ToHttpApiData UTCTime where
  toUrlPiece = timeToUrlPiece "%H:%M:%S%QZ"
  toEncodedUrlPiece = unsafeToEncodedUrlPiece

-- |
-- >>> toUrlPiece Monday
-- "monday"
instance ToHttpApiData DayOfWeek where
  toUrlPiece Monday    = "monday"
  toUrlPiece Tuesday   = "tuesday"
  toUrlPiece Wednesday = "wednesday"
  toUrlPiece Thursday  = "thursday"
  toUrlPiece Friday    = "friday"
  toUrlPiece Saturday  = "saturday"
  toUrlPiece Sunday    = "sunday"

  toEncodedUrlPiece = unsafeToEncodedUrlPiece

-- | 
-- >>> toUrlPiece Q4
-- "q4"
instance ToHttpApiData QuarterOfYear where
  toUrlPiece Q1 = "q1"
  toUrlPiece Q2 = "q2"
  toUrlPiece Q3 = "q3"
  toUrlPiece Q4 = "q4"

-- |
-- >>> import Data.Time.Calendar.Quarter.Compat (Quarter (..))
-- >>> MkQuarter 8040
-- 2010-Q1
--
-- >>> toUrlPiece $ MkQuarter 8040
-- "2010-q1"
--
instance ToHttpApiData Quarter where
  toUrlPiece q = case toYearQuarter q of
    (y, qoy) -> T.pack (show y ++ "-" ++ f qoy)
    where
      f Q1 = "q1"
      f Q2 = "q2"
      f Q3 = "q3"
      f Q4 = "q4"

-- |
-- >>> import Data.Time.Calendar.Month.Compat (Month (..))
-- >>> MkMonth 24482
-- 2040-03
--
-- >>> toUrlPiece $ MkMonth 24482
-- "2040-03"
--
instance ToHttpApiData Month where
  toUrlPiece = T.pack . formatTime defaultTimeLocale "%Y-%m"

instance ToHttpApiData NominalDiffTime where
  toUrlPiece = toUrlPiece . nominalDiffTimeToSeconds
  toEncodedUrlPiece = unsafeToEncodedUrlPiece

instance ToHttpApiData String   where toUrlPiece = T.pack
instance ToHttpApiData Text     where toUrlPiece = id
instance ToHttpApiData L.Text   where toUrlPiece = L.toStrict

instance ToHttpApiData All where
  toUrlPiece        = coerce (toUrlPiece :: Bool -> Text)
  toEncodedUrlPiece = coerce (toEncodedUrlPiece :: Bool -> BS.Builder)

instance ToHttpApiData Any where
  toUrlPiece        = coerce (toUrlPiece :: Bool -> Text)
  toEncodedUrlPiece = coerce (toEncodedUrlPiece :: Bool -> BS.Builder)

instance ToHttpApiData a => ToHttpApiData (Dual a) where
  toUrlPiece        = coerce (toUrlPiece :: a -> Text)
  toEncodedUrlPiece = coerce (toEncodedUrlPiece :: a -> BS.Builder)

instance ToHttpApiData a => ToHttpApiData (Sum a) where
  toUrlPiece        = coerce (toUrlPiece :: a -> Text)
  toEncodedUrlPiece = coerce (toEncodedUrlPiece :: a -> BS.Builder)

instance ToHttpApiData a => ToHttpApiData (Product a) where
  toUrlPiece        = coerce (toUrlPiece :: a -> Text)
  toEncodedUrlPiece = coerce (toEncodedUrlPiece :: a -> BS.Builder)

instance ToHttpApiData a => ToHttpApiData (First a) where
  toUrlPiece        = coerce (toUrlPiece :: Maybe a -> Text)
  toEncodedUrlPiece = coerce (toEncodedUrlPiece :: Maybe a -> BS.Builder)

instance ToHttpApiData a => ToHttpApiData (Last a) where
  toUrlPiece        = coerce (toUrlPiece :: Maybe a -> Text)
  toEncodedUrlPiece = coerce (toEncodedUrlPiece :: Maybe a -> BS.Builder)

instance ToHttpApiData a => ToHttpApiData (Semi.Min a) where
  toUrlPiece        = coerce (toUrlPiece :: a -> Text)
  toEncodedUrlPiece = coerce (toEncodedUrlPiece :: a -> BS.Builder)

instance ToHttpApiData a => ToHttpApiData (Semi.Max a) where
  toUrlPiece        = coerce (toUrlPiece :: a -> Text)
  toEncodedUrlPiece = coerce (toEncodedUrlPiece :: a -> BS.Builder)

instance ToHttpApiData a => ToHttpApiData (Semi.First a) where
  toUrlPiece        = coerce (toUrlPiece :: a -> Text)
  toEncodedUrlPiece = coerce (toEncodedUrlPiece :: a -> BS.Builder)

instance ToHttpApiData a => ToHttpApiData (Semi.Last a) where
  toUrlPiece        = coerce (toUrlPiece :: a -> Text)
  toEncodedUrlPiece = coerce (toEncodedUrlPiece :: a -> BS.Builder)

-- |
-- >>> toUrlPiece (Just "Hello")
-- "just Hello"
instance ToHttpApiData a => ToHttpApiData (Maybe a) where
  toUrlPiece (Just x) = "just " <> toUrlPiece x
  toUrlPiece Nothing  = "nothing"

-- |
-- >>> toUrlPiece (Left "err" :: Either String Int)
-- "left err"
-- >>> toUrlPiece (Right 3 :: Either String Int)
-- "right 3"
instance (ToHttpApiData a, ToHttpApiData b) => ToHttpApiData (Either a b) where
  toUrlPiece (Left x)  = "left " <> toUrlPiece x
  toUrlPiece (Right x) = "right " <> toUrlPiece x

-- | /Note:/ this instance works correctly for alphanumeric name and value
--
-- >>> let Right c = parseUrlPiece "SESSID=r2t5uvjq435r4q7ib3vtdjq120" :: Either Text SetCookie
-- >>> toUrlPiece c
-- "SESSID=r2t5uvjq435r4q7ib3vtdjq120"
--
-- >>> toHeader c
-- "SESSID=r2t5uvjq435r4q7ib3vtdjq120"
--
instance ToHttpApiData SetCookie where
  toUrlPiece = decodeUtf8With lenientDecode . toHeader
  toHeader = LBS.toStrict . BS.toLazyByteString . renderSetCookie
  -- toEncodedUrlPiece = renderSetCookie -- doesn't do things.

-- | Note: this instance is not polykinded
instance ToHttpApiData a => ToHttpApiData (Tagged (b :: Type) a) where
  toUrlPiece        = coerce (toUrlPiece :: a -> Text)
  toHeader          = coerce (toHeader :: a -> ByteString)
  toQueryParam      = coerce (toQueryParam :: a -> Text)
  toEncodedUrlPiece = coerce (toEncodedUrlPiece ::  a -> BS.Builder)

-- | @since 0.4.2
instance ToHttpApiData a => ToHttpApiData (Const a b) where
  toUrlPiece        = coerce (toUrlPiece :: a -> Text)
  toHeader          = coerce (toHeader :: a -> ByteString)
  toQueryParam      = coerce (toQueryParam :: a -> Text)
  toEncodedUrlPiece = coerce (toEncodedUrlPiece ::  a -> BS.Builder)

-- | @since 0.4.2
instance ToHttpApiData a => ToHttpApiData (Identity a) where
  toUrlPiece        = coerce (toUrlPiece :: a -> Text)
  toHeader          = coerce (toHeader :: a -> ByteString)
  toQueryParam      = coerce (toQueryParam :: a -> Text)
  toEncodedUrlPiece = coerce (toEncodedUrlPiece ::  a -> BS.Builder)

-- |
-- >>> parseUrlPiece "_" :: Either Text ()
-- Right ()
instance FromHttpApiData () where
  parseUrlPiece = void $ Atto.char '_'

instance FromHttpApiData Char where
  parseUrlPiece = Atto.anyChar

-- | Parsing a @'Void'@ value is always an error, considering @'Void'@ as a data type with no constructors.
instance FromHttpApiData Void where
  parseUrlPiece = fail "Void cannot be parsed!"

instance FromHttpApiData Natural where
  parseUrlPiece = do
    n <- Atto.signed Atto.decimal
    if n < 0
      then fail ("underflow: " <> show n <> " (should be a non-negative integer)")
      else pure (fromInteger n)

instance FromHttpApiData Bool     where parseUrlPiece = parseBoundedUrlPiece "Bool"
instance FromHttpApiData Ordering where parseUrlPiece = parseBoundedUrlPiece "Ordering"
instance FromHttpApiData Double   where parseUrlPiece = Atto.rational
instance FromHttpApiData Float    where parseUrlPiece = Atto.rational
instance FromHttpApiData Int      where parseUrlPiece = parseBounded (Atto.signed Atto.decimal)
instance FromHttpApiData Int8     where parseUrlPiece = parseBounded (Atto.signed Atto.decimal)
instance FromHttpApiData Int16    where parseUrlPiece = parseBounded (Atto.signed Atto.decimal)
instance FromHttpApiData Int32    where parseUrlPiece = parseBounded (Atto.signed Atto.decimal)
instance FromHttpApiData Int64    where parseUrlPiece = parseBounded (Atto.signed Atto.decimal)
instance FromHttpApiData Integer  where parseUrlPiece = Atto.signed Atto.decimal
instance FromHttpApiData Word     where parseUrlPiece = parseBounded Atto.decimal
instance FromHttpApiData Word8    where parseUrlPiece = parseBounded Atto.decimal
instance FromHttpApiData Word16   where parseUrlPiece = parseBounded Atto.decimal
instance FromHttpApiData Word32   where parseUrlPiece = parseBounded Atto.decimal
instance FromHttpApiData Word64   where parseUrlPiece = parseBounded Atto.decimal
instance FromHttpApiData String   where parseUrlPiece = T.unpack <$> Atto.takeText
instance FromHttpApiData Text     where parseUrlPiece = Atto.takeText
instance FromHttpApiData L.Text   where parseUrlPiece = Atto.takeLazyText

-- | Note: this instance is not polykinded
instance F.HasResolution a => FromHttpApiData (F.Fixed (a :: Type)) where
    parseUrlPiece = Atto.rational

-- |
-- >>> toGregorian <$> parseUrlPiece "2016-12-01"
-- Right (2016,12,1)
instance FromHttpApiData Day where parseUrlPiece = Atto.day

-- |
-- >>> parseUrlPiece "14:55:01.333" :: Either Text TimeOfDay
-- Right 14:55:01.333
instance FromHttpApiData TimeOfDay where parseUrlPiece = Atto.timeOfDay

-- |
-- >>> parseUrlPiece "2015-10-03T14:55:01" :: Either Text LocalTime
-- Right 2015-10-03 14:55:01
instance FromHttpApiData LocalTime where parseUrlPiece = Atto.localTime

-- |
-- >>> parseUrlPiece "2015-10-03T14:55:01+0000" :: Either Text ZonedTime
-- Right 2015-10-03 14:55:01 +0000
--
-- >>> parseQueryParam "2016-12-31T01:00:00Z" :: Either Text ZonedTime
-- Right 2016-12-31 01:00:00 +0000
instance FromHttpApiData ZonedTime where parseUrlPiece = Atto.zonedTime

-- |
-- >>> parseUrlPiece "2015-10-03T00:14:24Z" :: Either Text UTCTime
-- Right 2015-10-03 00:14:24 UTC
instance FromHttpApiData UTCTime   where parseUrlPiece = Atto.utcTime

-- |
-- >>> parseUrlPiece "Monday" :: Either Text DayOfWeek
-- Right Monday
instance FromHttpApiData DayOfWeek where
  parseUrlPiece = foldr ((<>) . f) (fail "Invalid DayOfWeek") [Monday .. Sunday]
    where
      f dow = dow <$ Atto.asciiCI (toUrlPiece dow)


instance FromHttpApiData NominalDiffTime where parseUrlPiece = secondsToNominalDiffTime <$> parseUrlPiece

-- |
-- >>> parseUrlPiece "2021-01" :: Either Text Month
-- Right 2021-01
instance FromHttpApiData Month where parseUrlPiece = Atto.month

-- |
-- >>> parseUrlPiece "2021-q1" :: Either Text Quarter
-- Right 2021-Q1
instance FromHttpApiData Quarter where parseUrlPiece = Atto.quarter

-- |
-- >>> parseUrlPiece "q2" :: Either Text QuarterOfYear
-- Right Q2
--
-- >>> parseUrlPiece "Q3" :: Either Text QuarterOfYear
-- Right Q3
instance FromHttpApiData QuarterOfYear where
    parseUrlPiece = do
      _ <- Atto.satisfy $ \c -> c == 'q' || c == 'Q'
      Q1 <$ Atto.char '1' <|> Q2 <$ Atto.char '2' <|> Q3 <$ Atto.char '3' <|> Q4 <$ Atto.char '4'

instance FromHttpApiData All where parseUrlPiece = coerce (parseUrlPiece :: Atto.Parser Bool)
instance FromHttpApiData Any where parseUrlPiece = coerce (parseUrlPiece :: Atto.Parser Bool)

instance FromHttpApiData a => FromHttpApiData (Dual a)    where parseUrlPiece = coerce (parseUrlPiece :: Atto.Parser a)
instance FromHttpApiData a => FromHttpApiData (Sum a)     where parseUrlPiece = coerce (parseUrlPiece :: Atto.Parser a)
instance FromHttpApiData a => FromHttpApiData (Product a) where parseUrlPiece = coerce (parseUrlPiece :: Atto.Parser a)
instance FromHttpApiData a => FromHttpApiData (First a)   where parseUrlPiece = coerce (parseUrlPiece :: Atto.Parser (Maybe a))
instance FromHttpApiData a => FromHttpApiData (Last a)    where parseUrlPiece = coerce (parseUrlPiece :: Atto.Parser (Maybe a))

instance FromHttpApiData a => FromHttpApiData (Semi.Min a)    where parseUrlPiece = coerce (parseUrlPiece :: Atto.Parser a)
instance FromHttpApiData a => FromHttpApiData (Semi.Max a)    where parseUrlPiece = coerce (parseUrlPiece :: Atto.Parser a)
instance FromHttpApiData a => FromHttpApiData (Semi.First a)  where parseUrlPiece = coerce (parseUrlPiece :: Atto.Parser a)
instance FromHttpApiData a => FromHttpApiData (Semi.Last a)   where parseUrlPiece = coerce (parseUrlPiece :: Atto.Parser a)

-- |
-- >>> parseUrlPiece "Just 123" :: Either Text (Maybe Int)
-- Right (Just 123)
instance FromHttpApiData a => FromHttpApiData (Maybe a) where
  parseUrlPiece =
    Nothing <$ Atto.asciiCI "nothing"
      <|> Just <$> parseUrlPieceWithPrefix "Just "

-- |
-- >>> parseUrlPiece "Right 123" :: Either Text (Either String Int)
-- Right (Right 123)
instance (FromHttpApiData a, FromHttpApiData b) => FromHttpApiData (Either a b) where
  parseUrlPiece =
        Right <$> parseUrlPieceWithPrefix "Right "
    <|> Left  <$> parseUrlPieceWithPrefix "Left "

instance ToHttpApiData UUID.UUID where
    toUrlPiece = UUID.toText
    toHeader   = UUID.toASCIIBytes
    toEncodedUrlPiece = unsafeToEncodedUrlPiece

instance FromHttpApiData UUID.UUID where
    parseUrlPiece = do
      bytes <- Atto.take 36
      maybe (fail "invalid UUID") pure $ UUID.fromText bytes
    parseHeader   = do
      bytes <- AttoB.take 36
      maybe (fail "invalid UUID") pure $ UUID.fromASCIIBytes bytes


-- | Lenient parameters. 'FromHttpApiData' combinators always return `Right`.
--
-- @since 0.3.5
newtype LenientData a = LenientData { getLenientData :: Either Text a }
  deriving (Eq, Ord, Show, Read, Typeable, Data, Functor, Foldable, Traversable)

instance FromHttpApiData a => FromHttpApiData (LenientData a) where
  parseUrlPiece   = (LenientData . Right <$> parseUrlPiece) <|> (pure . LenientData $ Left "Lenient data")
  parseHeader     = (LenientData . Right <$> parseHeader) <|> (pure . LenientData $ Left "Lenient data")
  parseQueryParam = (LenientData . Right <$> parseQueryParam) <|> (pure . LenientData $ Left "Lenient data")

-- | /Note:/ this instance works correctly for alphanumeric name and value
--
-- >>> parseUrlPiece "SESSID=r2t5uvjq435r4q7ib3vtdjq120" :: Either Text SetCookie
-- Right (SetCookie {setCookieName = "SESSID", setCookieValue = "r2t5uvjq435r4q7ib3vtdjq120", setCookiePath = Nothing, setCookieExpires = Nothing, setCookieMaxAge = Nothing, setCookieDomain = Nothing, setCookieHttpOnly = False, setCookieSecure = False, setCookieSameSite = Nothing})
instance FromHttpApiData SetCookie where
  parseUrlPiece = parseSetCookie . encodeUtf8 <$> Atto.takeText
  parseHeader   = parseSetCookie <$> AttoB.takeByteString

-- | Note: this instance is not polykinded
instance FromHttpApiData a => FromHttpApiData (Tagged (b :: Type) a) where
  parseUrlPiece   = coerce (parseUrlPiece :: Atto.Parser a)
  parseHeader     = coerce (parseHeader :: AttoB.Parser a)
  parseQueryParam = coerce (parseQueryParam :: Atto.Parser a)

-- | @since 0.4.2
instance FromHttpApiData a => FromHttpApiData (Const a b) where
  parseUrlPiece   = coerce (parseUrlPiece :: Atto.Parser a)
  parseHeader     = coerce (parseHeader :: AttoB.Parser a)
  parseQueryParam = coerce (parseQueryParam :: Atto.Parser a)

-- | @since 0.4.2
instance FromHttpApiData a => FromHttpApiData (Identity a) where
  parseUrlPiece   = coerce (parseUrlPiece :: Atto.Parser a)
  parseHeader     = coerce (parseHeader :: AttoB.Parser a)
  parseQueryParam = coerce (parseQueryParam :: Atto.Parser a)

-------------------------------------------------------------------------------
-- Attoparsec helpers
-------------------------------------------------------------------------------

runAtto :: Atto.Parser a -> Text -> Either Text a
runAtto p t = case Atto.parseOnly (p <* Atto.endOfInput) t of
    Left err -> Left (T.pack err)
    Right x  -> Right x


