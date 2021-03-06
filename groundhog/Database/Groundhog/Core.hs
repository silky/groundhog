{-# LANGUAGE GADTs, TypeFamilies, ExistentialQuantification, MultiParamTypeClasses, FunctionalDependencies, FlexibleContexts, FlexibleInstances, GeneralizedNewtypeDeriving, EmptyDataDecls, ConstraintKinds, CPP #-}
{-# LANGUAGE UndecidableInstances #-} -- Required for Projection'
-- | This module defines the functions and datatypes used throughout the framework.
-- Most of them are for the internal use
module Database.Groundhog.Core
  ( 
  -- * Main types
    PersistEntity(..)
  , PersistValue(..)
  , PersistField(..)
  , SinglePersistField(..)
  , PurePersistField(..)
  , PrimitivePersistField(..)
  , Embedded(..)
  , Projection(..)
  , Projection'
  , RestrictionHolder
  , Unique
  , KeyForBackend(..)
  , BackendSpecific
  , ConstructorMarker
  , UniqueMarker
  , HFalse
  , HTrue
  , ZT (..) -- ZonedTime wrapper
  , Utf8(..)
  , fromUtf8
  , delim
  -- * Constructing expressions
  , Cond(..)
  , ExprRelation(..)
  , Update(..)
  , (~>)
  , FieldLike(..)
  , Assignable
  , SubField(..)
  , AutoKeyField(..)
  , FieldChain
  , NeverNull
  , UntypedExpr(..)
  , Expr(..)
  , Order(..)
  , HasSelectOptions(..)
  , SelectOptions(..)
  , limitTo
  , offsetBy
  , orderBy
  , distinct
  -- * Type description
  -- $types
  , DbTypePrimitive'(..)
  , DbTypePrimitive
  , DbType(..)
  , EntityDef'(..)
  , EntityDef
  , EmbeddedDef'(..)
  , EmbeddedDef
  , OtherTypeDef'(..)
  , OtherTypeDef
  , ConstructorDef'(..)
  , ConstructorDef
  , Constructor(..)
  , EntityConstr(..)
  , IsUniqueKey(..)
  , UniqueDef'(..)
  , UniqueDef
  , UniqueType(..)
  , ReferenceActionType(..)
  , ParentTableReference
  -- * Migration
  , SingleMigration
  , NamedMigrations
  , Migration
  -- * Database
  , PersistBackend(..)
  , DbDescriptor(..)
  , RowPopper
  , DbPersist(..)
  , runDbPersist
  -- * Connections and transactions
  , ConnectionManager(..)
  , SingleConnectionManager
  , Savepoint(..)
  ) where

import Blaze.ByteString.Builder (Builder, fromByteString, toByteString)
import Control.Applicative (Applicative)
import Control.Monad.Base (MonadBase (liftBase))
import Control.Monad.Logger (MonadLogger(..))
import Control.Monad.Trans.Class (MonadTrans(..))
import Control.Monad.IO.Class (MonadIO(..))
import Control.Monad.Trans.Control (MonadBaseControl (..), ComposeSt, defaultLiftBaseWith, defaultRestoreM, MonadTransControl (..))
import Control.Monad.Trans.Reader (ReaderT(..), runReaderT, mapReaderT)
import Control.Monad.Trans.State (StateT)
import Control.Monad.Reader (MonadReader(..))
import Control.Monad (liftM)
import qualified Control.Monad.Cont.Class as Mtl
import qualified Control.Monad.Error.Class as Mtl
import qualified Control.Monad.State.Class as Mtl
import qualified Control.Monad.Writer.Class as Mtl
import Data.ByteString.Char8 (ByteString)
import Data.Int (Int64)
import Data.Map (Map)
import Data.Time (Day, TimeOfDay, UTCTime)
import Data.Time.LocalTime (ZonedTime, zonedTimeToUTC, zonedTimeToLocalTime, zonedTimeZone)
import GHC.Exts (Constraint)

-- | Only instances of this class can be persisted in a database
class (PurePersistField (AutoKey v), PurePersistField (DefaultKey v)) => PersistEntity v where
  -- | This type is used for typesafe manipulation of separate fields of datatype v.
  -- Each constructor in 'Field' corresponds to its field in a datatype v.
  -- It is parametrised by constructor phantom type and field value type.
  data Field v :: ((* -> *) -> *) -> * -> *
  -- | A unique identifier of a value stored in a database. This may be a primary key, a constraint or unique indices. The second parameter is the key description.
  data Key v :: * -> *
  -- | This type is the default autoincremented key for the entity. If entity does not have such key, AutoKey v = ().
  type AutoKey v
  -- | This type is the default key for the entity.
  type DefaultKey v
  -- | It is HFalse for entity with one constructor and HTrue for sum types.
  type IsSumType v
  -- | Returns a complete description of the type
  entityDef :: DbDescriptor db => proxy db -> v -> EntityDef
  -- | Marshalls value to a list of 'PersistValue' ready for insert to a database
  toEntityPersistValues :: PersistBackend m => v -> m ([PersistValue] -> [PersistValue])
  -- | Constructs the value from the list of 'PersistValue'
  fromEntityPersistValues :: PersistBackend m => [PersistValue] -> m (v, [PersistValue])
  -- | Returns constructor number and a list of uniques names and corresponding field values
  getUniques :: DbDescriptor db => proxy db -> v -> (Int, [(String, [PersistValue] -> [PersistValue])])
  -- | Is internally used by FieldLike Field instance
  -- We could avoid this function if class FieldLike allowed FieldLike Fields Data or FieldLike (Fields Data). However that would require additional extensions in user-space code
  entityFieldChain :: DbDescriptor db => proxy db -> Field v c a -> FieldChain

-- | A holder for Unique constraints
data Unique (u :: (* -> *) -> *)
-- | Key marked with this type can have value for any backend
data BackendSpecific
-- | A phantom datatype to make instance head different @c (ConstructorMarker v)@
data ConstructorMarker v a
-- | A phantom datatype to make instance head different @u (UniqueMarker v)@
data UniqueMarker v a

-- | It allows to store autogenerated keys of one database in another if they have different datatype.
data KeyForBackend db v = (DbDescriptor db, PersistEntity v) => KeyForBackend (AutoKeyType db)

data HFalse
data HTrue

-- | Represents condition for a query.
data Cond db r =
    And (Cond db r) (Cond db r)
  | Or  (Cond db r) (Cond db r)
  | Not (Cond db r)
  | Compare ExprRelation (UntypedExpr db r) (UntypedExpr db r)
  | CondRaw (QueryRaw db r)
  | CondEmpty

data ExprRelation = Eq | Ne | Gt | Lt | Ge | Le deriving Show

data Update db r = forall f a . (Assignable f a, Projection' f db r a) => Update f (UntypedExpr db r)

-- | Defines sort order of a result-set
data Order db r = forall a f . (Projection' f db r a) => Asc  f
                | forall a f . (Projection' f db r a) => Desc f

-- | It is used to map field to column names. It can be either a column name for a regular field of non-embedded type or a list of this field and the outer fields in reverse order. Eg, fieldChain $ SomeField ~> Tuple2_0Selector may result in [(\"val0\", DbString), (\"some\", DbEmbedded False [dbType \"\", dbType True])].
type FieldChain = ((String, DbType), [(String, EmbeddedDef)])

-- | Any data that can be fetched from a database
class Projection p a | p -> a where
  type ProjectionDb p db :: Constraint
  type ProjectionRestriction p r :: Constraint
  -- | It returns multiple expressions that can be transformed into values which can be selected. Difflist is used for concatenation efficiency.
  projectionExprs :: (DbDescriptor db, ProjectionDb p db, ProjectionRestriction p r) => p -> [UntypedExpr db r] -> [UntypedExpr db r]
  -- | It is like 'fromPersistValues'. However, we cannot use it for projections in all cases. For the 'PersistEntity' instances 'fromPersistValues' expects entity id instead of the entity values.
  projectionResult :: PersistBackend m => p -> [PersistValue] -> m (a, [PersistValue])

class (Projection p a, ProjectionDb p db, ProjectionRestriction p r) => Projection' p db r a
instance (Projection p a, ProjectionDb p db, ProjectionRestriction p r) => Projection' p db r a

-- | This subset of Projection instances is for things that behave like fields. Namely, they can occur in condition expressions (for example, Field and SubField) and on the left side of update statements. For example \"lower(field)\" is a valid Projection, but not Field like because it cannot be on the left side. Datatypes that index PostgreSQL arrays \"arr[5]\" or access composites \"(comp).subfield\" are valid instances of Assignable.
class Projection f a => Assignable f a | f -> a

-- | This subset of Assignable is for plain database fields.
class Assignable f a => FieldLike f a | f -> a where
  fieldChain :: (DbDescriptor db, ProjectionDb f db) => proxy db -> f -> FieldChain

class PersistField v => Embedded v where
  data Selector v :: * -> *
  selectorNum :: Selector v a -> Int

infixl 5 ~>
-- | Accesses fields of the embedded datatypes. For example, @SomeField ==. (\"abc\", \"def\") ||. SomeField ~> Tuple2_0Selector ==. \"def\"@
(~>) :: (EntityConstr v c, FieldLike f a, DbDescriptor db, Projection' f db (RestrictionHolder v c) a, Embedded a) => f -> Selector a a' -> SubField db v c a'
field ~> sel = subField where
  subField = case fieldChain db field of
    ((name, typ), prefix) -> case typ of
      DbEmbedded emb@(EmbeddedDef _ ts) _ -> SubField (ts !! selectorNum sel, (name, emb):prefix)
      other -> error $ "(~>): cannot get subfield of non-embedded type " ++ show other
  db = (undefined :: SubField db v c a' -> proxy db) subField

newtype SubField db v (c :: (* -> *) -> *) a = SubField FieldChain

-- | It can be used in expressions like a regular field.
-- For example, @delete (AutoKeyField ==. k)@
-- or @delete (AutoKeyField ==. k ||. SomeField ==. \"DUPLICATE\")@
data AutoKeyField v (c :: (* -> *) -> *) where
  AutoKeyField :: AutoKeyField v c

data RestrictionHolder v (c :: (* -> *) -> *)

data SelectOptions db r hasLimit hasOffset hasOrder hasDistinct = SelectOptions {
    condOptions     :: Cond db r
  , limitOptions    :: Maybe Int
  , offsetOptions   :: Maybe Int
  , orderOptions    :: [Order db r]
    -- ^ False - no DISTINCT, True - DISTINCT
  , distinctOptions :: Bool
    -- ^ The name of the option and part of the SQL which will be put later
  , dbSpecificOptions  :: [(String, QueryRaw db r)]
  }

-- | This class helps to check that limit, offset, or order clauses are added to condition only once.
class HasSelectOptions a db r | a -> db r where
  type HasLimit a
  type HasOffset a
  type HasOrder a
  type HasDistinct a
  getSelectOptions :: a -> SelectOptions db r (HasLimit a) (HasOffset a) (HasOrder a) (HasDistinct a)

instance db' ~ db => HasSelectOptions (Cond db r) db' r where
  type HasLimit (Cond db r) = HFalse
  type HasOffset (Cond db r) = HFalse
  type HasOrder (Cond db r) = HFalse
  type HasDistinct (Cond db r) = HFalse
  getSelectOptions a = SelectOptions a Nothing Nothing [] False []

instance db' ~ db => HasSelectOptions (SelectOptions db r hasLimit hasOffset hasOrder hasDistinct) db' r where
  type HasLimit (SelectOptions db r hasLimit hasOffset hasOrder hasDistinct) = hasLimit
  type HasOffset (SelectOptions db r hasLimit hasOffset hasOrder hasDistinct) = hasOffset
  type HasOrder (SelectOptions db r hasLimit hasOffset hasOrder hasDistinct) = hasOrder
  type HasDistinct (SelectOptions db r hasLimit hasOffset hasOrder hasDistinct) = hasDistinct
  getSelectOptions = id

limitTo :: (HasSelectOptions a db r, HasLimit a ~ HFalse) => a -> Int -> SelectOptions db r HTrue (HasOffset a) (HasOrder a) (HasDistinct a)
limitTo opts lim = (getSelectOptions opts) {limitOptions = Just lim}

offsetBy :: (HasSelectOptions a db r, HasOffset a ~ HFalse) => a -> Int -> SelectOptions db r (HasLimit a) HTrue (HasOrder a) (HasDistinct a)
offsetBy opts off = (getSelectOptions opts) {offsetOptions = Just off}

orderBy :: (HasSelectOptions a db r, HasOrder a ~ HFalse) => a -> [Order db r] -> SelectOptions db r (HasLimit a) (HasOffset a) HTrue (HasDistinct a)
orderBy opts ord = (getSelectOptions opts) {orderOptions = ord}

-- | Select DISTINCT rows. @select $ distinct CondEmpty@
distinct :: (HasSelectOptions a db r, HasDistinct a ~ HFalse) => a -> SelectOptions db r (HasLimit a) (HasOffset a) (HasOrder a) HTrue
distinct opts = (getSelectOptions opts) {distinctOptions = True}

newtype DbPersist conn m a = DbPersist { unDbPersist :: ReaderT conn m a }
  deriving (Monad, MonadIO, Functor, Applicative, MonadTrans, MonadReader conn)

instance MonadBase IO m => MonadBase IO (DbPersist conn m) where
  liftBase = lift . liftBase

instance MonadTransControl (DbPersist conn) where
#if MIN_VERSION_monad_control(1, 0, 0)
  type StT (DbPersist conn) a = StT (ReaderT conn) a
  liftWith f = DbPersist $ ReaderT $ \r -> f $ \t -> runReaderT (unDbPersist t) r
  restoreT = DbPersist . ReaderT . const
#else
  newtype StT (DbPersist conn) a = StReader {unStReader :: a}
  liftWith f = DbPersist $ ReaderT $ \r -> f $ \t -> liftM StReader $ runReaderT (unDbPersist t) r
  restoreT = DbPersist . ReaderT . const . liftM unStReader
#endif

instance MonadBaseControl IO m => MonadBaseControl IO (DbPersist conn m) where
#if MIN_VERSION_monad_control(1, 0, 0)
  type StM (DbPersist conn m) a = ComposeSt (DbPersist conn) m a
  liftBaseWith = defaultLiftBaseWith
  restoreM     = defaultRestoreM
#else
  newtype StM (DbPersist conn m) a = StMSP {unStMSP :: ComposeSt (DbPersist conn) m a}
  liftBaseWith = defaultLiftBaseWith StMSP
  restoreM     = defaultRestoreM   unStMSP
#endif

instance MonadLogger m => MonadLogger (DbPersist conn m) where
  monadLoggerLog a b c = lift . monadLoggerLog a b c

runDbPersist :: Monad m => DbPersist conn m a -> conn -> m a
runDbPersist = runReaderT . unDbPersist

mapDbPersist :: (m a -> n b) -> DbPersist conn m a -> DbPersist conn n b
mapDbPersist f m = DbPersist $ mapReaderT f $ unDbPersist m

instance Mtl.MonadWriter w m => Mtl.MonadWriter w (DbPersist conn m) where
  writer = lift . Mtl.writer
  tell = lift . Mtl.tell
  listen = mapDbPersist Mtl.listen
  pass = mapDbPersist Mtl.pass

instance Mtl.MonadError e m => Mtl.MonadError e (DbPersist conn m) where
  throwError = lift . Mtl.throwError
  catchError m h = DbPersist $ Mtl.catchError (unDbPersist m) (unDbPersist . h)

instance Mtl.MonadCont m => Mtl.MonadCont (DbPersist conn m) where
  callCC = liftCallCC Mtl.callCC where
    liftCallCC callCC f = DbPersist $ ReaderT $ \ r ->
      callCC $ \ c ->
      runDbPersist (f (DbPersist . ReaderT . const . c)) r

instance Mtl.MonadState s m => Mtl.MonadState s (DbPersist conn m) where
  get = lift Mtl.get
  put = lift . Mtl.put
  state = lift . Mtl.state

class PrimitivePersistField (AutoKeyType db) => DbDescriptor db where
  -- | Type of the database default autoincremented key. For example, Sqlite has Int64
  type AutoKeyType db
  -- | Value of this type can be used as a part of a query. For example, it can be RenderS for relational databases, or BSON for MongoDB.
  type QueryRaw db :: * -> *
  -- | Name of backend
  backendName :: proxy db -> String

class (Monad m, DbDescriptor (PhantomDb m)) => PersistBackend m where
  -- | A token which defines the DB type. For example, different monads working with Sqlite, return may Sqlite type.
  type PhantomDb m
  -- | Insert a new record to a database and return its autogenerated key or ()
  insert        :: PersistEntity v => v -> m (AutoKey v)
  -- | Insert a new record to a database. For some backends it may be faster than 'insert'.
  insert_       :: PersistEntity v => v -> m ()
  -- | Try to insert a record and return Right newkey. If there is a constraint violation for the given constraint, Left oldkey is returned
  -- , where oldkey is an identifier of the record with the matching values.
  insertBy      :: (PersistEntity v, IsUniqueKey (Key v (Unique u))) => u (UniqueMarker v) -> v -> m (Either (AutoKey v) (AutoKey v))
  -- | Try to insert a record and return Right newkey. If there is a constraint violation for any constraint, Left oldkey is returned
  -- , where oldkey is an identifier of the record with the matching values. Note that if several constraints are violated, a key of an arbitrary matching record is returned.
  insertByAll   :: PersistEntity v => v -> m (Either (AutoKey v) (AutoKey v))
  -- | Replace a record with the given autogenerated key. Result is undefined if the record does not exist.
  replace       :: (PersistEntity v, PrimitivePersistField (Key v BackendSpecific)) => Key v BackendSpecific -> v -> m ()
  -- | Replace a record. The unique key marker defines what unique key of the entity is used.
  replaceBy     :: (PersistEntity v, IsUniqueKey (Key v (Unique u))) => u (UniqueMarker v) -> v -> m ()
  -- | Return a list of the records satisfying the condition. Example: @select $ (FirstField ==. \"abc\" &&. SecondField >. \"def\") \`orderBy\` [Asc ThirdField] \`limitTo\` 100@
  select        :: (PersistEntity v, EntityConstr v c, HasSelectOptions opts (PhantomDb m) (RestrictionHolder v c))
                => opts -> m [v]
  -- | Return a list of all records. Order is undefined. It can be useful for datatypes with multiple constructors.
  selectAll     :: PersistEntity v => m [(AutoKey v, v)]
  -- | Fetch an entity from a database
  get           :: (PersistEntity v, PrimitivePersistField (Key v BackendSpecific)) => Key v BackendSpecific -> m (Maybe v)
  -- | Fetch an entity from a database by its unique key
  getBy         :: (PersistEntity v, IsUniqueKey (Key v (Unique u))) => Key v (Unique u) -> m (Maybe v)
  -- | Update the records satisfying the condition. Example: @update [FirstField =. \"abc\"] $ FirstField ==. \"def\"@
  update        :: (PersistEntity v, EntityConstr v c) => [Update (PhantomDb m) (RestrictionHolder v c)] -> Cond (PhantomDb m) (RestrictionHolder v c) -> m ()
  -- | Remove the records satisfying the condition
  delete        :: (PersistEntity v, EntityConstr v c) => Cond (PhantomDb m) (RestrictionHolder v c) -> m ()
  -- | Remove the record with given key. No-op if the record does not exist
  deleteBy      :: (PersistEntity v, PrimitivePersistField (Key v BackendSpecific)) => Key v BackendSpecific -> m ()
  -- | Remove all records. The entity parameter is used only for type inference.
  deleteAll     :: PersistEntity v => v -> m ()
  -- | Count total number of records satisfying the condition
  count         :: (PersistEntity v, EntityConstr v c) => Cond (PhantomDb m) (RestrictionHolder v c) -> m Int
  -- | Count total number of records with all constructors. The entity parameter is used only for type inference
  countAll      :: PersistEntity v => v -> m Int
  -- | Fetch projection of some fields. Example: @project (SecondField, ThirdField) $ (FirstField ==. \"abc\" &&. SecondField >. \"def\") \`orderBy\` [Asc ThirdField] \`offsetBy\` 100@
  project       :: (PersistEntity v, EntityConstr v c, Projection' p (PhantomDb m) (RestrictionHolder v c) a, HasSelectOptions opts (PhantomDb m) (RestrictionHolder v c))
                => p
                -> opts
                -> m [a]
  -- | Check database schema and create migrations for the entity and the entities it contains
  migrate       :: PersistEntity v => v -> Migration m
  -- | Execute raw query
  executeRaw    :: Bool           -- ^ keep in cache
                -> String         -- ^ query
                -> [PersistValue] -- ^ positional parameters
                -> m ()
  -- | Execute raw query with results
  queryRaw      :: Bool           -- ^ keep in cache
                -> String         -- ^ query
                -> [PersistValue] -- ^ positional parameters
                -> (RowPopper m -> m a) -- ^ results processing function
                -> m a
  insertList    :: PersistField a => [a] -> m Int64
  getList       :: PersistField a => Int64 -> m [a]

type RowPopper m = m (Maybe [PersistValue])

type Migration m = StateT NamedMigrations m ()

-- | Datatype names and corresponding migrations
type NamedMigrations = Map String SingleMigration

-- | Either error messages or migration queries with safety flag and execution order
type SingleMigration = Either [String] [(Bool, Int, String)]

-- $types
-- These types describe the mapping between database schema and datatype. They hold table names, columns, constraints, etc. Some types below are parameterized by string type str and dbType. This is done to make them promotable to kind level.

-- | Describes an ADT.
data EntityDef' str dbType = EntityDef {
  -- | Entity name. @entityName (entityDef v) == persistName v@
    entityName   :: str
  -- | Database schema for the entity table and tables of its constructors
  , entitySchema :: Maybe str
  -- | Named types of the instantiated polymorphic type parameters
  , typeParams   :: [dbType]
  -- | List of entity constructors definitions
  , constructors :: [ConstructorDef' str dbType]
} deriving (Show, Eq)

type EntityDef = EntityDef' String DbType

-- | Describes an entity constructor
data ConstructorDef' str dbType = ConstructorDef {
  -- | Constructor name
    constrName    :: str
  -- | Autokey name if any
  , constrAutoKeyName :: Maybe str
  -- | Parameter names with their named type
  , constrParams  :: [(str, dbType)]
  -- | Uniqueness constraints on the constructor fiels
  , constrUniques :: [UniqueDef' str (Either (str, dbType) str)]
} deriving (Show, Eq)

type ConstructorDef = ConstructorDef' String DbType

-- | Phantom constructors are made instances of this class. This class should be used only by Template Haskell codegen
class Constructor c where
  -- returning ConstructorDef seems more logical, but it would require the value datatype
  -- it can be supplied either as a part of constructor type, eg instance Constructor (MyDataConstructor (MyData a)) which requires -XFlexibleInstances
  -- or as a separate type, eg instance Constructor MyDataConstructor (MyData a) which requires -XMultiParamTypeClasses
  -- | Returns constructor index which can be used to get ConstructorDef from EntityDef
  phantomConstrNum :: c (a :: * -> *) -> Int

-- | This class helps type inference in cases when query does not contain any fields which
-- define the constructor, but the entity has only one.
-- For example, in @select $ AutoKeyField ==. k@ the condition would need type annotation with constructor name only if we select a sum type.
class PersistEntity v => EntityConstr v c where
  entityConstrNum :: proxy v -> c (a :: * -> *) -> Int

class PurePersistField uKey => IsUniqueKey uKey where
  -- | Creates value of unique key using the data extracted from the passed value
  extractUnique :: uKey ~ Key v u => v -> uKey
  -- | Ordinal number of the unique constraint in the list returned by 'constrUniques'
  uniqueNum :: uKey -> Int

-- | Unique name and list of the fields that form a unique combination. The fields are parametrized to reuse this datatype both with field and DbType and with column name
data UniqueDef' str field = UniqueDef {
    uniqueDefName :: Maybe str
  , uniqueDefType :: UniqueType
  , uniqueDefFields :: [field]
} deriving (Show, Eq)

-- | Field is either a pair of entity field name and its type or an expression which will be used in query as-is.
type UniqueDef = UniqueDef' String (Either (String, DbType) String)

-- | Defines how to treat the unique set of fields for a datatype
data UniqueType = UniqueConstraint
                | UniqueIndex
                | UniquePrimary Bool -- ^ is autoincremented
  deriving (Show, Eq, Ord)

data ReferenceActionType = NoAction
                         | Restrict
                         | Cascade
                         | SetNull
                         | SetDefault
  deriving (Eq, Show)

-- | A DB data type. Naming attempts to reflect the underlying Haskell
-- datatypes, eg DbString instead of DbVarchar. Different databases may
-- have different representations for these types.
data DbTypePrimitive' str =
      DbString
    | DbInt32
    | DbInt64
    | DbReal
    | DbBool
    | DbDay
    | DbTime
    | DbDayTime
    | DbDayTimeZoned
    | DbBlob         -- ^ ByteString
    | DbOther (OtherTypeDef' str)
  deriving (Eq, Show)

type DbTypePrimitive = DbTypePrimitive' String

data DbType = 
    -- | type, nullable, default value, reference
      DbTypePrimitive DbTypePrimitive Bool (Maybe String) (Maybe ParentTableReference)
    | DbEmbedded EmbeddedDef (Maybe ParentTableReference)
    | DbList String DbType -- ^ List table name and type of its argument
  deriving (Eq, Show)

-- | The reference contains either EntityDef of the parent table and name of the unique constraint. Or for tables not mapped by Groundhog schema name, table name, and list of columns  
-- Reference to the autogenerated key of a mapped entity = (Left (entityDef, Nothing), onDelete, onUpdate)
-- Reference to a unique key of a mapped entity = (Left (entityDef, Just uniqueKeyName), onDelete, onUpdate)
-- Reference to a table that is not mapped = (Right ((schema, tableName), columns), onDelete, onUpdate)
type ParentTableReference = (Either (EntityDef, Maybe String) ((Maybe String, String), [String]), Maybe ReferenceActionType, Maybe ReferenceActionType)

-- | Stores a database type. The list contains two kinds of tokens for the type string. Backend will choose a string representation for DbTypePrimitive's, and the string literals will go to the type as-is. As the final step, these tokens are concatenated. For example, @[Left \"varchar(50)\"]@ will become a string with max length and @[Right DbInt64, Left \"[]\"]@ will become integer[] in PostgreSQL.
newtype OtherTypeDef' str = OtherTypeDef ([Either str (DbTypePrimitive' str)]) deriving (Eq, Show)

type OtherTypeDef = OtherTypeDef' String

-- | The first argument is a flag which defines if the field names should be concatenated with the outer field name (False) or used as is which provides full control over table column names (True).
-- Value False should be the default value so that a datatype can be embedded without name conflict concern. The second argument list of field names and field types.
data EmbeddedDef' str dbType = EmbeddedDef Bool [(str, dbType)] deriving (Eq, Show)

type EmbeddedDef = EmbeddedDef' String DbType

-- | Datatype for incremental building SQL queries
newtype Utf8 = Utf8 Builder
instance Eq Utf8 where
  a == b = fromUtf8 a == fromUtf8 b
instance Show Utf8 where
  show = show . fromUtf8
instance Read Utf8 where
  readsPrec prec str = map (\(a, b) -> (Utf8 $ fromByteString a, b)) $ readsPrec prec str

fromUtf8 :: Utf8 -> ByteString
fromUtf8 (Utf8 a) = toByteString a

-- | A raw value which can be stored in any backend and can be marshalled to
-- and from a 'PersistField'.
data PersistValue = PersistString String
                  | PersistByteString ByteString
                  | PersistInt64 Int64
                  | PersistDouble Double
                  | PersistBool Bool
                  | PersistDay Day
                  | PersistTimeOfDay TimeOfDay
                  | PersistUTCTime UTCTime
                  | PersistZonedTime ZT
                  | PersistNull
                  -- | Creating some datatypes may require calling a function, using a special constructor, or other syntax. The string (which can have placeholders) is included into query without escaping. The recursive constructions are not allowed, i.e., [PersistValue] cannot contain PersistCustom values.
                  | PersistCustom Utf8 [PersistValue]
  deriving (Eq, Show, Read)

-- | Avoid orphan instances.
newtype ZT = ZT ZonedTime deriving (Show, Read)

instance Eq ZT where
    ZT a == ZT b = zonedTimeToLocalTime a == zonedTimeToLocalTime b && zonedTimeZone a == zonedTimeZone b
instance Ord ZT where
    ZT a `compare` ZT b = zonedTimeToUTC a `compare` zonedTimeToUTC b

-- | Types which are never NULL when converted to 'PersistValue'.
-- Consider the type @Maybe (Maybe a)@. Now Nothing is stored as NULL, so we cannot distinguish between Just Nothing and Nothing which is a problem.
-- The purpose of this class is to ban the inner Maybe's.
-- Maybe this class can be removed when support for inner Maybe's appears.
class NeverNull a

-- | Used to uniformly represent fields, constants and more complex things, e.g., arithmetic expressions.
-- A value should be converted to 'UntypedExpr' for usage in expressions
data UntypedExpr db r where
  ExprRaw :: QueryRaw db r -> UntypedExpr db r
  ExprField :: FieldChain -> UntypedExpr db r
  ExprPure :: forall db r a . PurePersistField a => a -> UntypedExpr db r
  ExprCond :: Cond db r -> UntypedExpr db r

-- | Expr with phantom type helps to keep type safety in complex expressions
newtype Expr db r a = Expr (UntypedExpr db r)
instance Show (Expr db r a) where show _ = "Expr"
instance Eq (Expr db r a) where (==) = error "(==): this instance Eq (Expr db r a) is made only for Num superclass constraint"

-- | Represents everything which can be put into a database. This data can be stored in multiple columns and tables. To get value of those columns we might need to access another table. That is why the result type is monadic.
class PersistField a where
  -- | Return name of the type. If it is polymorphic, the names of parameter types are separated with 'Database.Groundhog.Generic.delim' symbol
  persistName :: a -> String
  -- | Convert a value into something which can be stored in a database column.
  -- Note that for complex datatypes it may insert them to return identifier
  toPersistValues :: PersistBackend m => a -> m ([PersistValue] -> [PersistValue])
  -- | Constructs a value from a 'PersistValue'. For complex datatypes it may query the database
  fromPersistValues :: PersistBackend m => [PersistValue] -> m (a, [PersistValue])
  -- | Description of value type. It depends on database so that we can have, for example, xml column type in Postgres and varchar type in other databases
  dbType :: DbDescriptor db => proxy db -> a -> DbType

-- | Represents all datatypes that map into a single column. Getting value for that column might require monadic actions to access other tables.
class PersistField a => SinglePersistField a where
  toSinglePersistValue :: PersistBackend m => a -> m PersistValue
  fromSinglePersistValue :: PersistBackend m => PersistValue -> m a

-- | Represents all datatypes that map into several columns. Getting values for those columns is pure.
class PersistField a => PurePersistField a where
  toPurePersistValues :: DbDescriptor db => proxy db -> a -> ([PersistValue] -> [PersistValue])
  fromPurePersistValues :: DbDescriptor db => proxy db -> [PersistValue] -> (a, [PersistValue])

-- | Datatypes which can be converted directly to 'PersistValue'. The no-value parameter @DbDescriptor db => proxy db@ allows conversion depend the database details while keeping it pure. A type which has an instance of 'PrimitivePersistField' should be an instance of superclasses 'SinglePersistField' and 'PurePersistField' as well.
class PersistField a => PrimitivePersistField a where
  toPrimitivePersistValue :: DbDescriptor db => proxy db -> a -> PersistValue
  fromPrimitivePersistValue :: DbDescriptor db => proxy db -> PersistValue -> a

delim :: Char
delim = '#'

-- | Connection manager provides connection to the passed function handles transations. Manager can be a connection itself, a pool, Snaplet in Snap, foundation datatype in Yesod, etc.
class ConnectionManager cm conn | cm -> conn where
  -- | Extracts the connection from manager and opens the transaction.
  withConn :: (MonadBaseControl IO m, MonadIO m) => (conn -> m a) -> cm -> m a
  -- | Extracts the connection.
  withConnNoTransaction :: (MonadBaseControl IO m, MonadIO m) => (conn -> m a) -> cm -> m a

-- | This connection manager always returns the same connection. This constraint is useful when performing operations which make sense only within one connection, for example, nested savepoints..
class ConnectionManager cm conn => SingleConnectionManager cm conn

class Savepoint conn where
  -- | Wraps the passed action into a named savepoint
  withConnSavepoint :: (MonadBaseControl IO m, MonadIO m) => String -> m a -> conn -> m a
