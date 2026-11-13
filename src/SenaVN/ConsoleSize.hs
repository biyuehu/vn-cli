{-# LANGUAGE CPP #-}
{-# LANGUAGE ForeignFunctionInterface #-}

module SenaVN.ConsoleSize (getConsoleWidth) where

#if defined(mingw32_HOST_OS)
import Foreign
import Foreign.C.String
import Foreign.C.Types

data SMALL_RECT = SMALL_RECT CShort CShort CShort CShort

instance Storable SMALL_RECT where
  sizeOf _ = 8
  alignment _ = 2
  peek ptr = do
    l <- peekByteOff ptr 0
    t <- peekByteOff ptr 2
    r <- peekByteOff ptr 4
    b <- peekByteOff ptr 6
    pure (SMALL_RECT l t r b)
  poke _ _ = error "no poke"

foreign import ccall "windows.h CreateFileW"
  c_CreateFileW :: CWString -> Word32 -> Word32 -> Ptr () -> Word32 -> Word32 -> Ptr () -> IO (Ptr ())

foreign import ccall "windows.h GetConsoleScreenBufferInfo"
  c_GetConsoleScreenBufferInfo :: Ptr () -> Ptr () -> IO Int32

foreign import ccall "windows.h CloseHandle"
  c_CloseHandle :: Ptr () -> IO Int32

getConsoleWidth :: IO (Maybe Int)
getConsoleWidth = withCWString "CONOUT$" $ \conout -> do
  h <- c_CreateFileW conout 0xC0000000 3 nullPtr 3 0 nullPtr
  if h == nullPtr || h == wordPtrToPtr 0xFFFFFFFFFFFFFFFF
    then pure Nothing
    else allocaBytes 22 $ \pCsbi -> do
      res <- c_GetConsoleScreenBufferInfo h pCsbi
      _ <- c_CloseHandle h
      if res == 0
        then pure Nothing
        else do
          SMALL_RECT l _ r _ <- peek (plusPtr pCsbi 10)
          pure (Just (fromIntegral (r - l + 1)))
#else
import Foreign
import Foreign.C.Types

#if defined(darwin_HOST_OS)
-- TIOCGWINSZ on macOS is 0x40087468
tiocgwinsz :: CULong
tiocgwinsz = 0x40087468
#else
-- TIOCGWINSZ on Linux is 0x5413
tiocgwinsz :: CULong
tiocgwinsz = 0x5413
#endif

foreign import ccall "sys/ioctl.h ioctl"
  c_ioctl :: CInt -> CULong -> Ptr () -> IO CInt

getConsoleWidth :: IO (Maybe Int)
getConsoleWidth = allocaBytes 8 $ \pWinsize -> do
  res <- c_ioctl 1 tiocgwinsz pWinsize
  if res /= 0
    then pure Nothing
    else do
      wsCol <- peekByteOff pWinsize 2 :: IO CUShort
      if wsCol == 0
        then pure Nothing
        else pure (Just (fromIntegral wsCol))
#endif

