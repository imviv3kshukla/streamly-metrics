{-# LANGUAGE FlexibleContexts #-}
module Aggregator
    ( translateThreadEvents
    , Counter (..)
    , Location (..)
    , collectThreadCounter
    )
where

import Data.Int (Int64)
import Data.Word (Word32)
import EventParser (Event (..))
import Streamly.Internal.Data.Fold (Fold(..), Step(..))
import Streamly.Internal.Data.Tuple.Strict (Tuple'(..))

import qualified Data.Map.Strict as Map
import qualified Data.Set as Set

-------------------------------------------------------------------------------
-- Event processing
-------------------------------------------------------------------------------

-- XXX We attach a user event to a thread by looking at the previous thread
-- start event. But when there are multiple capabilities this may not be
-- possible? We need to use the thread-id on the same capability as the user
-- event. Or we can emit the tid in the user event. How does ghc-events-analyze
-- handle this? or the user event can log the thread-id as part of the tag.

data Counter =
      ThreadCPUTime
    | ThreadCPUTimeWall
    | ThreadUserTime
    | ThreadSystemTime
    | ThreadCtxVoluntary
    | ThreadCtxInvoluntary
    | ThreadPageFaultMinor
    | ThreadPageFaultMajor
    | ThreadIOBlockIn
    | ThreadIOBlockOut
    deriving (Show, Eq, Ord)

data Location = Start | Stop | OneShot deriving Show

-- XXX It would be more intuitive for scans if we use "Partial s b" instead of
-- using extract. We can avoid having to save the result in state many a times.

{-# INLINE translateThreadEvents #-}
translateThreadEvents ::
    Fold IO Event [((Word32, String, Counter), (Location, Int64))]
translateThreadEvents = Fold step initial extract

    where

    initial = pure $ Partial $ Tuple' Map.empty []

    threadEvent2 mp tid ctr1 v1 ctr2 v2 =
        pure $ Partial $ Tuple' mp
            ((if v1 /= 0
            then [((tid, "default", ctr1), (OneShot, (fromIntegral v1)))]
            else []) ++
            (if v2 /= 0
            then [((tid, "default", ctr2), (OneShot, (fromIntegral v2)))]
            else []))

    threadEventBcast mp tid ts ctr loc = do
        let r = Map.lookup tid mp
        case r of
            Just set ->
                pure $ Partial $ Tuple' mp (fmap f ("default" : Set.toList set))
            Nothing ->
                pure $ Partial $ Tuple' mp [f "default"]

        where

        f x = ((tid, x, ctr), (loc, (fromIntegral ts)))

    threadEvent mp tid ts ctr loc =
        pure $ Partial $ Tuple' mp [f "default"]

        where

        f x = ((tid, x, ctr), (loc, (fromIntegral ts)))

    windowStart mp tid tag ts ctr loc = do
        let mp1 = Map.alter alter tid mp
        pure $ Partial $ Tuple' mp1 [f tag]

        where

        alter Nothing = Just $ Set.singleton tag
        alter (Just set) = Just $ Set.insert tag set

        f x = ((tid, x, ctr), (loc, (fromIntegral ts)))

    windowEnd mp tid tag ts ctr loc = do
        let mp1 = Map.alter alter tid mp
        pure $ Partial $ Tuple' mp1 [f tag]

        where

        alter Nothing = error "Window end when window does not exist"
        alter (Just set) = Just $ Set.delete tag set

        f x = ((tid, x, ctr), (loc, (fromIntegral ts)))

    -- CPUTime
    step (Tuple' mp _) (StartThreadCPUTime tid ts) =
        threadEventBcast mp tid ts ThreadCPUTime Start
    step (Tuple' mp _) (StopThreadCPUTime tid ts) =
        threadEventBcast mp tid ts ThreadCPUTime Stop
    step (Tuple' mp _) (StartWindowCPUTime tid tag ts) =
        windowStart mp tid tag ts ThreadCPUTime Start
    step (Tuple' mp _) (StopWindowCPUTime tid tag ts) =
        windowEnd mp tid tag ts ThreadCPUTime Stop

    step (Tuple' mp _) (StartThreadCPUTimeWall tid ts) =
        threadEvent mp tid ts ThreadCPUTimeWall Start
    step (Tuple' mp _) (StopThreadCPUTimeWall tid ts) =
        threadEvent mp tid ts ThreadCPUTimeWall Stop

    -- User time
    step (Tuple' mp _) (StartThreadUserTime tid ts) =
        threadEvent mp tid ts ThreadUserTime Start
    step (Tuple' mp _) (StopThreadUserTime tid ts) =
        threadEvent mp tid ts ThreadUserTime Stop

    step (Tuple' mp _) (StartThreadSystemTime tid ts) =
        threadEvent mp tid ts ThreadSystemTime Start
    step (Tuple' mp _) (StopThreadSystemTime tid ts) =
        threadEvent mp tid ts ThreadSystemTime Stop

    step (Tuple' mp _) (ThreadCtxSwitches tid vol invol) =
        threadEvent2 mp tid ThreadCtxVoluntary vol ThreadCtxInvoluntary invol

    step (Tuple' mp _) (ThreadPageFaults tid minor major) =
        threadEvent2 mp tid ThreadPageFaultMinor minor ThreadPageFaultMajor major

    step (Tuple' mp _) (ThreadIOBlocks tid ioIn ioOut) =
        threadEvent2 mp tid ThreadIOBlockIn ioIn ThreadIOBlockOut ioOut

    step (Tuple' mp _) (Unknown _ _) =
        pure $ Partial $ Tuple' mp []

    extract (Tuple' _ xs) = pure xs

data CollectState = CollectInit | CollectPartial Int64 | CollectDone Int64

{-# INLINE collectThreadCounter #-}
collectThreadCounter :: Fold IO (Location, Int64) (Maybe Int64)
collectThreadCounter = Fold step initial extract

    where

    initial = pure $ Partial CollectInit

    step CollectInit (Start, v) =
        pure $ Partial $ CollectPartial v
    step CollectInit stat@(Stop, _) = do
        putStrLn $ "Error: Stop event when counter is not initialized." ++ show stat
        pure $ Partial CollectInit
    step CollectInit (OneShot, v) =
        pure $ Partial $ CollectDone v

    -- Same handling as CollectInit
    step (CollectDone _) (Start, v)
        = pure $ Partial $ CollectPartial v
    step acc@(CollectDone _) stat@(Stop, _) = do
        putStrLn $ "Error: Stop event when counter is not initialized." ++ show stat
        pure $ Partial acc
    step (CollectDone _) (OneShot, v) =
        pure $ Partial $ CollectDone v

    step (CollectPartial old) (Stop, new) = do
            -- putStrLn $ "new = " ++ show new ++ " old = " ++ show old
            let delta = new - old
            if delta < 0
                then error $ "counter delta is negative:"
                        ++  "new = " ++ show new ++ " old = " ++ show old
                else pure ()
            pure $ Partial $ CollectDone delta
    step (CollectPartial _) stat@(Start, v) = do
        putStrLn $ "Error: Got a duplicate thread start event " ++ show stat
        pure $ Partial $ CollectPartial v
    step (CollectPartial _) (OneShot, v) = do
        putStrLn $ "Error: Bad event data, cannot be in CollectPartial state for a one shot counter."
        pure $ Partial $ CollectDone v

    extract CollectInit = pure Nothing
    extract (CollectPartial _) = pure Nothing
    extract (CollectDone v) = pure (Just v)
