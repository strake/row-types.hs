{-# LANGUAGE TypeOperators, NoMonomorphismRestriction, ScopedTypeVariables,GADTs, KindSignatures, MultiParamTypeClasses, FlexibleInstances, FlexibleContexts, TypeFamilies, ViewPatterns, DataKinds, ConstraintKinds, UndecidableInstances,FunctionalDependencies,Rank2Types,AllowAmbiguousTypes, InstanceSigs #-}
-----------------------------------------------------------------------------
-- |
-- Module      :  OpenRecVar
-- Copyright   :  (c) Atze van der Ploeg 2013
-- License     :  BSD-style
-- Maintainer  :  atzeus@gmail.org
-- Stability   :  expirimental
-- 
-- This module implements extensible records  as 
-- described in paper `Extensible Records with Scoped Labels`,
-- Daan Leijen, Proc. 2005 Symp. Trends in Functional Programming
-- available at <http://research.microsoft.com/pubs/65409/scopedlabels.pdf>
--
-- See Examples.hs for examples.
-- 
-- The main difference with the paper is that this module does not extend
-- the type system, but instead uses closed type families, GADTs and
-- type level symbols to implement the system. 
--
-- For this a small extension to GHC is needed which implements the 
-- built-in closed type family 
--  @type family (m :: Symbol) <=.? (n :: Symbol) :: Bool@
-- where Symbol is a type literal.
--
-- Patches to implement this extension to GHC (patchmain) and the base library (patchlib) are also found in the 
-- git repo that hosts this project <https://github.com/atzeus/openrec>
-- I've sent these patches to Iavor Diatchki (who is implementing the type literal stuff) to get these (small) changes into the main repo.
--
-- This small extension allows us to keep lists of (label,type) pairs sorted thereby ensuring
-- that { x = 0, y = 0 } and { y = 0, x = 0 } have the same type.
-- 
-- In this way we can implement standard type classes such as Show, Eq, Ord and Bounded
-- for open records, given that all the elements of the open record satify the constraint.
-- 
-----------------------------------------------------------------------------


module Records

 (

             -- *  Labels and label type pairs
             KnownSymbol(..),
             Label(..),
             LT(..),
             -- * Rows
             Row, Empty , (:|), (:!), (:-),(:\),
             -- * Records
             Rec,   
             empty,
             RecordOp(..),
              (.|),
             (.!),
             (.-),
             Forall(..),
     ) 
where

import Data.Map(Map,unionWith)
import Data.Sequence(Seq,viewl,ViewL(..),(><),(<|))
import qualified Data.Map as M
import qualified Data.Sequence as S
import Unsafe.Coerce
import Data.List
import GHC.TypeLits
import GHC.Exts -- needed for constraints kinds
import Debug.Trace

{--------------------------------------------------------------------
  Labels and Label value pairs
--------------------------------------------------------------------}

-- | A label 
data Label (s :: Symbol) = Label

instance KnownSymbol s => Show (Label s) where
  show = symbolVal

infixr 6 :->
-- | A label-type pair (data kind) 
data LT b = Symbol :-> b

{--------------------------------------------------------------------
  Row operations
--------------------------------------------------------------------}

newtype Row a = R [LT a] -- constructor not exported

type family Empty :: Row * where
  Empty = R '[]

infixr 5 :|
-- | Extend the row with a label-type pair
type family (l :: LT *) :|  (r :: Row *) :: Row * where
  l :| (R x) = R (Inject l x)

infixl 6 :!
-- | Get the type associated with a label
type family (r :: Row *) :! (t :: Symbol) :: * where
  (R r) :! l = Get l r

-- | Remove a label from a row
type family (r :: Row *) :- (s :: Symbol)  :: Row * where
  (R r) :- l = R (Remove l r)

type family (l :: Row *) :++  (r :: Row *)  :: Row * where
  (R l) :++ (R r) = R (Merge l r)

type family (l :: Row *) :+  (r :: Row *)  :: Row * where
  (R l) :+ (R r) = R (Merge l r)

-- | Does the row lack (i.e. it has not) the specified label?
class (r :: Row *) :\ (l :: Symbol)
instance (Lacks l r ~ LabelUnique l) => (R r) :\ l

-- | Are the two rows disjoint? (i.e. their set of labels is disjoint)
class (l :: Row *) :\\ (r :: Row *)
instance (Disjoint l r ~ IsDisjoint) => (R l) :\\ (R r)

-- private things for row operations


-- gives nicer error message than Bool
data Unique = LabelUnique Symbol | LabelNotUnique Symbol

type family Inject (l :: LT *) (r :: [LT *]) where
  Inject (l :-> t) '[] = (l :-> t ': '[])
  Inject (l :-> t) (l' :-> t' ': x) = 
      Ifte (l <=.? l')
      (l :-> t   ': l' :-> t' ': x)
      (l' :-> t' ': (Inject (l :-> t)  x))

type family Ifte (c :: Bool) (t :: [LT *]) (f :: [LT *])   where
  Ifte True  t f = t
  Ifte False t f = f

type family Get (l :: Symbol) (r :: [LT *]) where
  Get l (l :-> t ': x) = t
  Get l (l' :-> t ': x) = Get l x

type family Remove (l :: Symbol) (r :: [LT *]) where
  Remove l (l :-> t ': x) = x
  Remove l (l' :-> t ': x) = l' :-> t ': Remove l x

type family Lacks (l :: Symbol) (r :: [LT *]) where
  Lacks l '[] = LabelUnique l
  Lacks l (l :-> t ': x) = LabelNotUnique l

type family Merge (l :: [LT *]) (r :: [LT *]) where
  Merge '[] r = r
  Merge l '[] = l
  Merge (hl :-> al ': tl) (hr :-> ar ': tr) = 
      Ifte (hl <=.? hr)
      (hl :-> al ': Merge tl (hr :-> ar ': tr))
      (hr :-> ar ': Merge (hl :-> al ': tl) tr)

-- gives nicer error message than Bool
data DisjointErr = IsDisjoint | Duplicate Symbol

type family IfteD (c :: Bool) (t :: DisjointErr) (f :: DisjointErr)   where
  IfteD True  t f = t
  IfteD False t f = f


type family Disjoint (l :: [LT *]) (r :: [LT *]) where
    Disjoint '[] r = IsDisjoint
    Disjoint l '[] = IsDisjoint
    Disjoint (l :-> al ': tl) (l :-> ar ': tr) = Duplicate l
    Disjoint (hl :-> al ': tl) (hr :-> ar ': tr) = 
      IfteD (hl <=.? hr)
      (Disjoint tl (hr :-> ar ': tr))
      (Disjoint (hl :-> al ': tl) tr)


{--------------------------------------------------------------------
  Open records
--------------------------------------------------------------------}

data HideType where
  HideType :: a -> HideType

-- | Openrecord type
data Rec (r :: Row *) where
  OR :: Map String (Seq HideType) -> Rec r

-- | The empty record
empty :: Rec Empty
empty = OR M.empty

infix 5 :=
infix 5 :!=
infix 5 :<-
data RecordOp in' out where
   -- |  Record extension
  (:=)  :: KnownSymbol l           => Label l -> a      -> RecordOp r (l :-> a :| r)
  -- | Record extension, without shadowing
  (:!=) :: (KnownSymbol l, r :\ l) => Label l -> a      -> RecordOp r (l :-> a :| r)
  -- | Record update
  (:<-) :: KnownSymbol l           => Label l -> r :! l -> RecordOp r r 

-- | Apply an operation to a record.
infixr 4 .|
(.|) :: RecordOp r r' -> Rec r -> Rec r'
((show -> l) := a) .| (OR m)  = OR $ M.insert l v m where v = HideType a <| M.findWithDefault S.empty l m
((show -> l) :!= a) .| (OR m) = OR $ M.insert l v m where v = HideType a <| M.findWithDefault S.empty l m
((show -> l) :<- a) .| (OR m) = OR $ M.adjust f l m where f = S.update 0 (HideType a)  


infix  8 .-
-- | Record selection
(.!) :: KnownSymbol l => Rec r -> Label l -> r :! l
(OR m) .! (show -> a) = x'
   where x S.:< t =  S.viewl $ m M.! a 
         -- notice that this is safe because of the external type
         x' = case x of HideType p -> unsafeCoerce p 

-- | Record restriction
(.-) :: KnownSymbol l =>  Rec r -> Label l -> Rec (r :- l)
(OR m) .- (show -> a) = OR m'
   where x S.:< t =  S.viewl $ m M.! a 
         m' = case S.viewl t of
               EmptyL -> M.delete a m
               _      -> M.insert a t m

-- | Record merge (not commutative)
(.++) :: Rec l -> Rec r -> Rec (l :++ r)
(OR l) .++ (OR r) = OR $ M.unionWith (><) l r

-- | Record disjoint union (commutative)
(.+) :: (l :\\ r) => Rec l -> Rec r -> Rec (l :+ r)
(OR l) .+ (OR r) = OR $ M.unionWith (error "Impossible") l r


unsafeInjectFront :: KnownSymbol l => Label l -> a -> Rec (R r) -> Rec (R (l :-> a ': r))
unsafeInjectFront (show -> a) b (OR m) = OR $ M.insert a v m
  where v = HideType b <| M.findWithDefault S.empty a m


class GetLabels (r :: Row *) where
  getLabels :: Rec r -> [String]

instance GetLabels (R '[]) where
  getLabels _ = []

instance (KnownSymbol l, GetLabels (R t)) =>  GetLabels (R (l :-> a ': t)) where
  getLabels r = show l : getLabels (r .- l) where
     l = Label :: Label l

class Forall (r :: Row *) (c :: * -> Constraint) where
 rinit     :: (forall a. c a => a) -> Rec r
 erase    :: (forall a. c a => a -> b) -> Rec r -> [b]
 eraseZip :: (forall a. c a => a -> a -> b) -> Rec r -> Rec r -> [b]

instance Forall (R '[]) c where
  rinit _ = empty
  erase _ _ = []
  eraseZip _ _ _ = []

instance (KnownSymbol l, Forall (R t) c, c a) => Forall (R (l :-> a ': t)) c where
  rinit f = unsafeInjectFront l a (initnxt f) where
    l = Label :: Label l
    a = (f :: a)
    initnxt = rinit :: (forall a. c a => a) -> Rec (R t)
  erase ::  forall b. (forall a. c a => a -> b) -> Rec (R (l :-> a ': t)) -> [b]
  erase f r = f (r .! l) : erasenxt f (r .- l) where
    l = Label :: Label l
    erasenxt = erase :: (forall a. c a => a ->  b) -> Rec (R t) -> [b]
  eraseZip ::  forall b. (forall a. c a => a -> a ->  b) -> Rec (R ((l :-> a) ': t)) ->  Rec (R ((l :-> a) ': t)) -> [b]
  eraseZip f x y = f (x .! l) (y .! l) : erasenxt f (x .- l) (y .- l) where
    l = Label :: Label l
    erasenxt = eraseZip :: (forall a. c a => a -> a -> b) -> Rec (R t) -> Rec (R t) -> [b]
  
-- some standard type classes

instance (GetLabels r, Forall r Show) => Show (Rec r) where
  show r = "{ " ++ meat ++ " }"
    where meat = intercalate ", " binds
          binds = zipWith (\x y -> x ++ "=" ++ y) ls vs
          ls = getLabels r
          vs = toStv show r
          -- i don't know exactly why this explicit typing is needed...
          toStv = erase ::  (forall a. Show a => a -> String) -> Rec r -> [String]

instance (Forall r Eq) => Eq (Rec r) where
  r == r' = and $ eqt (==) r r'
      where -- i don't know exactly why this explicit typing is needed...
            eqt = eraseZip ::  (forall a. Eq a => a -> a -> Bool) -> Rec r -> Rec r -> [Bool]


instance (Eq (Rec r), Forall r Ord) => Ord (Rec r) where
  compare m m' = cmp $ eqt compare m m'
      where -- i don't know exactly why this explicit typing is needed...
            eqt = eraseZip ::  (forall a. Ord a => a -> a -> Ordering) -> Rec r -> Rec r -> [Ordering]
            cmp l | [] <- l' = EQ
                  | a : _ <- l' = a
                  where l' = dropWhile (== EQ) l


instance (Forall r Bounded) => Bounded (Rec r) where
  minBound = hinitv minBound
       where hinitv = rinit :: (forall a. Bounded a => a) -> Rec r
  maxBound = hinitv maxBound
       where hinitv = rinit :: (forall a. Bounded a => a) -> Rec r

                            



