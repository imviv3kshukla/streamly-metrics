module Streamly.Metrics.RUsage
    (
      pattern RUsageSelf
    , pattern RUsageChildren
--    , RUsageThread
    , RUsage(..)
    , getRUsage
    )
where

import Control.Applicative ()
import Data.Word (Word64)
import Foreign.C.Error (throwErrnoIfMinus1_)
import Foreign.C.Types (CInt(..), CLong)
import Foreign.Marshal.Alloc (alloca)
import Foreign.Ptr (Ptr)
import Foreign.Storable (Storable(..))

#include <sys/time.h>
#include <sys/resource.h>

-------------------------------------------------------------------------------
-- Unsafe cast operations
-------------------------------------------------------------------------------

clongToW64 :: CLong -> Word64
clongToW64 = fromIntegral

w64ToCLong :: Word64 -> CLong
w64ToCLong = fromIntegral

-------------------------------------------------------------------------------
-- struct timeval
-------------------------------------------------------------------------------

data TimeVal =
    TimeVal
        {-# UNPACK #-} !Word64 -- sec
        {-# UNPACK #-} !Word64 -- usec
        deriving (Show, Eq)

instance Storable TimeVal where
    alignment _ = 8

    sizeOf _ = #const sizeof(struct timeval)

    peek p = do
        s <- (#peek struct timeval, tv_sec) p
        us <- (#peek struct timeval, tv_usec) p
        return $ TimeVal (clongToW64 s) (clongToW64 us)

    poke p (TimeVal s us) = do
        (#poke struct timeval, tv_sec) p (w64ToCLong s)
        (#poke struct timeval, tv_usec) p (w64ToCLong us)

{------------------------------------------------------------------------------
The resource usages are returned in the structure pointed to by usage, which
has the following form:

   struct rusage {
       struct timeval ru_utime; /* user CPU time used */
       struct timeval ru_stime; /* system CPU time used */
       long   ru_maxrss;        /* maximum resident set size */
       long   ru_ixrss;         /* integral shared memory size */
       long   ru_idrss;         /* integral unshared data size */
       long   ru_isrss;         /* integral unshared stack size */
       long   ru_minflt;        /* page reclaims (soft page faults) */
       long   ru_majflt;        /* page faults (hard page faults) */
       long   ru_nswap;         /* swaps */
       long   ru_inblock;       /* block input operations */
       long   ru_oublock;       /* block output operations */
       long   ru_msgsnd;        /* IPC messages sent */
       long   ru_msgrcv;        /* IPC messages received */
       long   ru_nsignals;      /* signals received */
       long   ru_nvcsw;         /* voluntary context switches */
       long   ru_nivcsw;        /* involuntary context switches */
   };
------------------------------------------------------------------------------}

data RUsage = RUsage
    { ru_utime    :: {-# UNPACK #-} !Double
    , ru_stime    :: {-# UNPACK #-} !Double
    , ru_maxrss   :: {-# UNPACK #-} !Word64
    , ru_ixrss    :: {-# UNPACK #-} !Word64
    , ru_idrss    :: {-# UNPACK #-} !Word64
    , ru_isrss    :: {-# UNPACK #-} !Word64
    , ru_minflt   :: {-# UNPACK #-} !Word64
    , ru_majflt   :: {-# UNPACK #-} !Word64
    , ru_nswap    :: {-# UNPACK #-} !Word64
    , ru_inblock  :: {-# UNPACK #-} !Word64
    , ru_oublock  :: {-# UNPACK #-} !Word64
    , ru_msgsnd   :: {-# UNPACK #-} !Word64
    , ru_msgrcv   :: {-# UNPACK #-} !Word64
    , ru_nsignals :: {-# UNPACK #-} !Word64
    , ru_nvcsw    :: {-# UNPACK #-} !Word64
    , ru_nivcsw   :: {-# UNPACK #-} !Word64
    } deriving (Show, Eq)

-- | convert TimeVal to seconds
timeValToDouble :: TimeVal -> Double
timeValToDouble (TimeVal s us) =
    fromIntegral s + fromIntegral us * 1e-6

-- | convert seconds to TimeVal
doubleToTimeVal :: Double -> TimeVal
doubleToTimeVal sec =
    let (s, us) = round (sec * 1e6) `divMod` (10^(6::Int))
     in TimeVal s us

instance Storable RUsage where
    alignment _ = 8

    sizeOf _ = #const sizeof(struct rusage)

    peek p =
        RUsage
            <$> (timeValToDouble <$> (#peek struct rusage, ru_utime) p)
            <*> (timeValToDouble <$> (#peek struct rusage, ru_stime) p)
            <*> (clongToW64 <$> (#peek struct rusage, ru_maxrss  ) p)
            <*> (clongToW64 <$> (#peek struct rusage, ru_ixrss   ) p)
            <*> (clongToW64 <$> (#peek struct rusage, ru_idrss   ) p)
            <*> (clongToW64 <$> (#peek struct rusage, ru_isrss   ) p)
            <*> (clongToW64 <$> (#peek struct rusage, ru_minflt  ) p)
            <*> (clongToW64 <$> (#peek struct rusage, ru_majflt  ) p)
            <*> (clongToW64 <$> (#peek struct rusage, ru_nswap   ) p)
            <*> (clongToW64 <$> (#peek struct rusage, ru_inblock ) p)
            <*> (clongToW64 <$> (#peek struct rusage, ru_oublock ) p)
            <*> (clongToW64 <$> (#peek struct rusage, ru_msgsnd  ) p)
            <*> (clongToW64 <$> (#peek struct rusage, ru_msgrcv  ) p)
            <*> (clongToW64 <$> (#peek struct rusage, ru_nsignals) p)
            <*> (clongToW64 <$> (#peek struct rusage, ru_nvcsw   ) p)
            <*> (clongToW64 <$> (#peek struct rusage, ru_nivcsw  ) p)

    poke p RUsage{..} = do
        (#poke struct rusage, ru_utime)    p (doubleToTimeVal ru_utime)
        (#poke struct rusage, ru_stime)    p (doubleToTimeVal ru_stime)
        (#poke struct rusage, ru_maxrss)   p (w64ToCLong ru_maxrss)
        (#poke struct rusage, ru_ixrss)    p (w64ToCLong ru_ixrss)
        (#poke struct rusage, ru_idrss)    p (w64ToCLong ru_idrss)
        (#poke struct rusage, ru_isrss)    p (w64ToCLong ru_isrss)
        (#poke struct rusage, ru_minflt)   p (w64ToCLong ru_minflt)
        (#poke struct rusage, ru_majflt)   p (w64ToCLong ru_majflt)
        (#poke struct rusage, ru_nswap)    p (w64ToCLong ru_nswap)
        (#poke struct rusage, ru_inblock)  p (w64ToCLong ru_inblock)
        (#poke struct rusage, ru_oublock)  p (w64ToCLong ru_oublock)
        (#poke struct rusage, ru_msgsnd)   p (w64ToCLong ru_msgsnd)
        (#poke struct rusage, ru_msgrcv)   p (w64ToCLong ru_msgrcv)
        (#poke struct rusage, ru_nsignals) p (w64ToCLong ru_nsignals)
        (#poke struct rusage, ru_nvcsw)    p (w64ToCLong ru_nvcsw)
        (#poke struct rusage, ru_nivcsw)   p (w64ToCLong ru_nivcsw)

-------------------------------------------------------------------------------
-- data Who = RUsageSelf | RUsageChildren | RUsageThread
-------------------------------------------------------------------------------

pattern RUsageSelf :: CInt
pattern RUsageSelf = (#const RUSAGE_SELF) :: CInt

pattern RUsageChildren :: CInt
pattern RUsageChildren = (#const RUSAGE_CHILDREN) :: CInt

{-
pattern RUsageThread :: CInt
pattern RUsageThread = (#const RUSAGE_THREAD) :: CInt
-}

-------------------------------------------------------------------------------
-- int getrusage(int who, struct rusage *usage);
-------------------------------------------------------------------------------

-- | See "man getrusage".
foreign import ccall unsafe "getrusage" c_getrusage ::
    CInt -> Ptr RUsage -> IO CInt

-- | "who" could be:
-- RUsageSelf
-- RUsageChildren
-- RUsageThread
getRUsage :: CInt -> IO RUsage
getRUsage who =
    alloca $ \ptr -> do
        throwErrnoIfMinus1_ "getrusage" (c_getrusage who ptr)
        peek ptr
