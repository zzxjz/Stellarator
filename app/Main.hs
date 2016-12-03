{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE BinaryLiterals #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE PatternSynonyms #-}

module Main where

import Binary
import Control.Applicative
import Control.Concurrent (threadDelay)
import Control.Lens hiding (_last)
import Control.Monad
import Control.Monad.State
import Data.Array.IO
import Data.Array.Unboxed
import Data.Binary
import System.Exit
import Data.Binary.Get
import Data.Bits hiding (bit)
import Data.Bits.Lens
import Data.ByteString as B hiding (last, putStr, putStrLn, getLine, length, elem, map, reverse)
import Data.Char
import Data.Int
import Data.Monoid
import Data.Word
import Foreign.C.Types
import Foreign.Ptr
import System.Random
import Foreign.Storable
import Numeric
import SDL.Event
import SDL.Input.Keyboard
import SDL.Vect
import SDL.Video.Renderer
import System.Console.CmdArgs hiding ((+=))
import System.IO
--import System.Random
import TIAColors
import qualified Data.ByteString.Internal as BS (c2w, w2c)
import qualified SDL
import Debug.Trace
import Prelude hiding (last)
import Core


{-# INLINE i8 #-}
i8 :: Integral a => a -> Word8
i8 = fromIntegral

{-# INLINE i16 #-}
i16 :: Integral a => a -> Word16
i16 = fromIntegral

{-# INLINE iz #-}
iz :: Word16 -> Int -- or NUM
iz = fromIntegral

{-# INLINABLE dumpRegisters #-}
dumpRegisters :: Emu6502 m => m ()
dumpRegisters = do
    -- XXX bring clock back
    --tClock <- use clock
    --debugStr 9 $ "clock = " ++ show tClock
    regPC <- getPC
    debugStr 0 $ " pc = " ++ showHex regPC ""
    regP <- getP
    debugStr 0 $ " flags = " ++ showHex regP ""
    debugStr 0 $ "(N=" ++ showHex ((regP `shift` (-7)) .&. 1) ""
    debugStr 0 $ ",V=" ++ showHex ((regP `shift` (-6)) .&. 1) ""
    debugStr 0 $ ",B=" ++ showHex (regP `shift` ((-4)) .&. 1) ""
    debugStr 0 $ ",D=" ++ showHex (regP `shift` ((-3)) .&. 1) ""
    debugStr 0 $ ",I=" ++ showHex (regP `shift` ((-2)) .&. 1) ""
    debugStr 0 $ ",Z=" ++ showHex (regP `shift` ((-1)) .&. 1) ""
    debugStr 0 $ ",C=" ++ showHex (regP .&. 1) ""
    regA <- getA 
    debugStr 0 $ ") A = " ++ showHex regA ""
    regX <- getX
    debugStr 0 $ " X = " ++ showHex regX ""
    regY <- getY
    debugStrLn 0 $ " Y = " ++ showHex regY ""
    regS <- getS
    debugStrLn 0 $ " N = " ++ showHex regS ""

{-# INLINABLE dumpMemory #-}
dumpMemory :: Emu6502 m => m ()
dumpMemory = do
    regPC <- getPC
    b0 <- readMemory regPC
    b1 <- readMemory (regPC+1)
    b2 <- readMemory (regPC+2)
    debugStr 0 $ "(PC) = "
    debugStr 0 $ showHex b0 "" ++ " "
    debugStr 0 $ showHex b1 "" ++ " "
    debugStrLn 0 $ showHex b2 ""

{-# INLINABLE dumpState #-}
dumpState :: Emu6502 m => m ()
dumpState = do
    dumpMemory
    dumpRegisters

newtype OReg = OReg Word16 deriving (Ord, Ix, Eq, Num)
newtype IReg = IReg Word16 deriving (Ord, Ix, Eq, Num)

nusiz0, nusiz1, colup0, colup1, pf0, pf1, pf2, enam0, enam1, hmp0, hmp1, hmm0, hmm1, hmbl :: OReg
vsync, refp0, refp1, colupf, colubk, ctrlpf, resmp0, resmp1 :: OReg
vsync = 0x00
nusiz0 = 0x04
nusiz1 = 0x05
colup0 = 0x06
colup1 = 0x07
colupf = 0x08
colubk = 0x09
ctrlpf = 0x0a
refp0 = 0x0b
refp1 = 0x0c
pf0 = 0x0d
pf1 = 0x0e
pf2 = 0x0f
enam0 = 0x1d
enam1 = 0x1e
hmp0 = 0x20
hmp1 = 0x21
hmm0 = 0x22
hmm1 = 0x23
hmbl = 0x24
resmp0 = 0x28
resmp1 = 0x29

cxm0p, cxm1p, cxp0fb, cxp1fb, cxm0fb, cxm1fb, cxblpf, cxppmm, inpt4, inpt5 :: IReg
cxm0p = 0x00
cxm1p = 0x01
cxp0fb = 0x02
cxp1fb = 0x03
cxm0fb = 0x04
cxm1fb = 0x05
cxblpf = 0x06
cxppmm = 0x07
inpt4 = 0x0c
inpt5 = 0x0d

data IntervalTimer = IntervalTimer {
    _intim :: !Word8,
    _subtimer :: !CInt,
    _interval :: !CInt
}

$(makeLenses ''IntervalTimer)

data Graphics = Graphics {
    _delayP0 :: !Bool,
    _delayP1 :: !Bool,
    _delayBall :: !Bool,
    _oldGrp0 :: !Word8,
    _newGrp0 :: !Word8,
    _oldGrp1 :: !Word8,
    _newGrp1 :: !Word8,
    _oldBall :: !Bool,
    _newBall :: !Bool
}

$(makeLenses ''Graphics)

data Sprites = Sprites {
    _s_ppos0 :: !CInt,
    _s_ppos1 :: !CInt,
    _s_mpos0 :: !CInt,
    _s_mpos1 :: !CInt,
    _s_bpos :: !CInt
}

$(makeLenses ''Sprites)

data StellaClock = Clock {
    _now :: !Int64,
    _last :: !Int64
}

$(makeLenses ''StellaClock)

data StellaDebug = Debug {
    _debugLevel :: !Int,
    _xbreak :: !Int32,
    _ybreak :: !Int32
}

$(makeLenses '' StellaDebug)

data Stella = Stella {
     _oregisters :: IOUArray OReg Word8,
     _iregisters :: IOUArray IReg Word8,

    _vblank :: !Word8,
    _swcha :: !Word8,
    _swchb :: !Word8,

    _stellaDebug :: StellaDebug,

    _backSurface :: !Surface,
    _frontSurface :: !Surface,
    _frontWindow :: !SDL.Window,

    _stellaClock :: StellaClock,
    _position :: (CInt, CInt),
    _graphics :: Graphics,
    _sprites :: Sprites,
    _intervalTimer :: IntervalTimer
}

$(makeLenses ''Stella)

{-# INLINE hpos #-}
{-# INLINE vpos #-}
hpos, vpos :: Lens' Stella CInt
hpos = position . _1
vpos = position . _2

{-# INLINE ppos0 #-}
{-# INLINE ppos1 #-}
{-# INLINE mpos0 #-}
{-# INLINE mpos1 #-}
{-# INLINE bpos #-}
ppos0, ppos1, mpos0, mpos1, bpos :: Lens' Stella CInt
ppos0 = sprites . s_ppos0
ppos1 = sprites . s_ppos1
mpos0 = sprites . s_mpos0
mpos1 = sprites . s_mpos1
bpos = sprites . s_bpos

{-# INLINE nowClock #-}
{-# INLINE lastClock #-}
nowClock, lastClock :: Lens' Stella Int64
nowClock = stellaClock . now
lastClock = stellaClock . last

{- INLINE stellaDebugStr -}
stellaDebugStr :: (MonadIO m, MonadState Stella m) =>
                  Int -> String -> m ()
stellaDebugStr n str = do
    d <- use (stellaDebug . debugLevel)
    if n <= d
        then do
            before <- use lastClock
            now <- use nowClock
            liftIO $ putStr $ show now ++ " +" ++ show (now-before) ++ ": " ++ str
            lastClock .= now
        else return ()

{- INLINE stellaDebugStrLn -}
stellaDebugStrLn :: (MonadIO m, MonadState Stella m) =>
                    Int -> String -> m ()
stellaDebugStrLn n str = do
    d <- use (stellaDebug . debugLevel)
    if n <= d
        then do
            before <- use lastClock
            now <- use nowClock
            liftIO $ putStrLn $ show now ++ " +" ++ show (now-before) ++ ": " ++ str
            lastClock .= now
        else return ()

{-# INLINE putORegister #-}
putORegister :: (MonadIO m, MonadState Stella m) => OReg -> Word8 -> m ()
putORegister i v = do
    r <- use oregisters
    liftIO $ writeArray r i v

{-# INLINE getORegister #-}
getORegister :: (MonadIO m, MonadState Stella m) => OReg -> m Word8
getORegister i = do
    r <- use oregisters
    liftIO $ readArray r i

{-# INLINE putIRegister #-}
putIRegister :: (MonadIO m, MonadState Stella m) => IReg -> Word8 -> m ()
putIRegister i v = do
    r <- use iregisters
    liftIO $ writeArray r i v

{-# INLINE getIRegister #-}
getIRegister :: (MonadIO m, MonadState Stella m) => IReg -> m Word8
getIRegister i = do
    r <- use iregisters
    liftIO $ readArray r i

{-# INLINE orIRegister #-}
orIRegister :: (MonadIO m, MonadState Stella m) => IReg -> Word8 -> m ()
orIRegister i v = do
    r <- use iregisters
    liftIO $ readArray r i >>= writeArray r i . (v .|.)

inBinary :: (Bits a) => Int -> a -> String
inBinary 0 x = ""
inBinary n x = inBinary (n-1) (x `shift` (-1)) ++ if testBit x 0 then "1" else "0"

explainNusiz :: Word8 -> String
explainNusiz nusiz =
    case nusiz .&. 0b111 of
        0b000 -> "one copy"
        0b001 -> "two copies - close"
        0b010 -> "two copies - med"
        0b011 -> "three copies - close"
        0b100 -> "two copies - wide"
        0b101 -> "double size player"
        0b110 -> "3 copies medium"
        0b111 -> "quad sized player"

dumpStella :: (MonadIO m, MonadState Stella m) => m ()
dumpStella = do
    liftIO $ putStrLn "--------"
    hpos' <- use hpos
    vpos' <- use vpos
    liftIO $ putStrLn $ "hpos = " ++ show hpos' ++ " (" ++ show (hpos'-picx) ++ ") vpos = " ++ show vpos' ++ " (" ++ show (vpos'-picy) ++ ")"
    grp0' <- use (graphics . oldGrp0) -- XXX
    grp1' <- use (graphics . oldGrp1) -- XXX
    liftIO $ putStrLn $ "GRP0 = " ++ showHex grp0' "" ++ "(" ++ inBinary 8 grp0' ++ ")"
    liftIO $ putStrLn $ "GRP1 = " ++ showHex grp1' "" ++ "(" ++ inBinary 8 grp1' ++ ")"
    pf0' <- getORegister pf0
    pf1' <- getORegister pf1
    pf2' <- getORegister pf2
    liftIO $ putStrLn $ "PF = " ++ reverse (inBinary 4 (pf0' `shift` (-4)))
                                ++ inBinary 8 pf1'
                                ++ reverse (inBinary 8 pf2')
    nusiz0' <- getORegister nusiz0
    nusiz1' <- getORegister nusiz1
    liftIO $ putStrLn $ "NUSIZ0 = " ++ showHex nusiz0' "" ++ "(" ++ explainNusiz nusiz0' ++
                        ") NUSIZ1 = " ++ showHex nusiz1' "" ++ "(" ++ explainNusiz nusiz1' ++ ")"
    enam0' <- getORegister enam0
    enam1' <- getORegister enam1
    enablOld <- use (graphics . oldBall)
    enablNew <- use (graphics . newBall)
    liftIO $ putStr $ "ENAM0 = " ++ show (testBit enam0' 1)
    liftIO $ putStr $ " ENAM1 = " ++ show (testBit enam1' 1)
    liftIO $ putStrLn $ " ENABL = " ++ show (enablOld, enablNew)
    mpos0' <- use mpos0
    mpos1' <- use mpos1
    hmm0' <- getORegister hmm0
    hmm1' <- getORegister hmm1
    liftIO $ putStr $ "missile0 @ " ++ show mpos0' ++ "(" ++ show (clockMove hmm0') ++ ")"
    liftIO $ putStrLn $ " missile1 @ " ++ show mpos1' ++ "(" ++ show (clockMove hmm1') ++ ")"
    vdelp0' <- use (graphics . delayP0)
    vdelp1' <- use (graphics . delayP1)
    vdelbl' <- use (graphics . delayBall)
    liftIO $ putStrLn $ "VDELP0 = " ++ show vdelp0' ++ " " ++
                        "VDELP1 = " ++ show vdelp1' ++ " " ++
                        "VDELBL = " ++ show vdelbl'
    

{- INLINE playfield -}
playfield :: (MonadIO m, MonadState Stella m) => Int -> m Bool
playfield i | i >= 0 && i < 4 = flip testBit (i+4) <$> getORegister pf0
            | i >=4 && i < 12 = flip testBit (11-i) <$> getORegister pf1
            | i >= 12 && i < 20 = flip testBit (i-12) <$> getORegister pf2
playfield i | i >= 20 && i < 40 = do
                ctrlpf' <- getORegister ctrlpf
                playfield $ if testBit ctrlpf' 0 then 39-i else i-20

{-# INLINE flipIf #-}
flipIf :: Bool -> Int -> Int
flipIf True x = x
flipIf False x = 7-x

{- INLINE stretchPlayer -}
stretchPlayer :: Bool -> Word8 -> CInt -> Word8 -> Bool
stretchPlayer reflect sizeCopies o bitmap =
    case sizeCopies of
        0b000 -> -- one copy
            if o >= 0 && o < 8
                then testBit bitmap (flipIf reflect $ fromIntegral o)
                else False
        0b001 -> -- two copies close
            if o >= 0 && o < 8 || o >= 16 && o < 24
                then testBit bitmap (flipIf reflect $ fromIntegral (o .&. 7))
                else False
        0b010 -> -- two copies - med
            if o >= 0 && o < 8 || o >= 32 && o < 40
                then testBit bitmap (flipIf reflect $ fromIntegral (o .&. 7))
                else False
        0b011 -> -- three copies close
            if o >= 0 && o < 8 || o >= 16 && o < 24 || o >= 32 && o < 40
                then testBit bitmap (flipIf reflect $ fromIntegral (o .&. 7))
                else False
        0b100 -> -- two copies wide
            if o >= 0 && o < 8 || o >= 64 && o < 72
                then testBit bitmap (flipIf reflect $ fromIntegral (o .&. 7))
                else False
        0b101 -> -- double size player
            if o >= 0 && o < 16
                then testBit bitmap (flipIf reflect $ fromIntegral ((o `shift` (-1)) .&. 7))
                else False
        0b110 -> -- three copies medium
            if o >= 0 && o < 8 || o >= 32 && o < 40 || o >= 64 && o < 72
                then testBit bitmap (flipIf reflect $ fromIntegral (o .&. 7))
                else False
        0b111 -> -- quad sized player
            if o >= 0 && o < 32
                then testBit bitmap (flipIf reflect $ (fromIntegral ((o `shift` (-2)) .&. 7)))
                else False

-- Stella programmer's guide p.40
{- INLINE player0 -}
player0 :: (MonadIO m, MonadState Stella m) => m Bool
player0 = do
    o <- (-) <$> use hpos <*> use ppos0
    sizeCopies <- (0b111 .&.) <$> getORegister nusiz0
    delayP0' <- use (graphics . delayP0)
    grp0' <- if delayP0'
        then use (graphics . oldGrp0)
        else use (graphics . newGrp0)
    refp0' <- getORegister refp0
    return $ stretchPlayer (testBit refp0' 3) sizeCopies o grp0'

{- INLINE player1 -}
player1 :: (MonadIO m, MonadState Stella m) => m Bool
player1 = do
    o <- (-) <$> use hpos <*> use ppos1
    sizeCopies <- (0b111 .&.) <$> getORegister nusiz1
    delayP1' <- use (graphics . delayP1)
    grp1' <- if delayP1'
        then use (graphics . oldGrp1)
        else use (graphics . newGrp1)
    refp1' <- getORegister refp1
    return $ stretchPlayer (testBit refp1' 3) sizeCopies o grp1'

missileSize :: Word8 -> CInt
missileSize nusiz = 1 `shift` (fromIntegral ((nusiz `shift` (-4)) .&. 0b11))

-- Stella programmer's guide p.22
{- INLINE missile0 -}
missile0 :: (MonadIO m, MonadState Stella m) => m Bool
missile0 = do
    enam0' <- getORegister enam0
    resmp0' <- getORegister resmp0
    if testBit resmp0' 1
        then do
            use hpos >>= (mpos0 .=)
            return False
        else if testBit enam0' 1
            then do
                o <- (-) <$> use hpos <*> use mpos0
                nusiz0' <- getORegister nusiz0
                return $ o >= 0 && o < missileSize nusiz0'
            else return False


{- INLINE missile1 -}
missile1 :: (MonadIO m, MonadState Stella m) => m Bool
missile1 = do
    enam1' <- getORegister enam1
    resmp1' <- getORegister resmp1
    if (testBit resmp1' 1)
        then do 
            use hpos >>= (mpos1 .=) -- XXX may need to do this on resmp
            return False
        else if testBit enam1' 1
            then do
                o <- (-) <$> use hpos <*> use mpos1
                nusiz1' <- getORegister nusiz1
                return $ o >= 0 && o < missileSize nusiz1'
            else return False

{- INLINE ball -}
ball :: (MonadIO m, MonadState Stella m) => m Bool
ball = do
    delayBall' <- use (graphics . delayBall)
    enabl' <- if delayBall'
        then use (graphics . oldBall)
        else use (graphics . newBall)
    if enabl'
        then do
            o <- (-) <$> use hpos <*> use bpos
            ctrlpf' <- getORegister ctrlpf
            let ballSize = 1 `shift` (fromIntegral ((ctrlpf' `shift` (fromIntegral $ -4)) .&. 0b11))
            return $ o >= 0 && o < ballSize
        else return False

screenWidth, screenHeight :: CInt
(screenWidth, screenHeight) = (160, 192)

{-# INLINE clockMove #-}
clockMove :: Word8 -> CInt
clockMove i = fromIntegral ((fromIntegral i :: Int8) `shift` (-4))

{- INLINE stellaHmclr -}
stellaHmclr :: (MonadIO m, MonadState Stella m) => m ()
stellaHmclr = do
    putORegister hmp0 0
    putORegister hmp1 0
    putORegister hmm0 0
    putORegister hmm1 0
    putORegister hmbl 0

{- INLINE stellaCxclr -}
stellaCxclr :: (MonadIO m, MonadState Stella m) => m ()
stellaCxclr = do
    putIRegister cxm0p 0
    putIRegister cxm1p 0
    putIRegister cxm0fb 0
    putIRegister cxm1fb 0
    putIRegister cxp0fb 0
    putIRegister cxp1fb 0
    putIRegister cxblpf 0
    putIRegister cxppmm 0

{-# INLINE wrap160 #-}
wrap160 :: CInt -> CInt
wrap160 i | i>=picx && i < picx+160 = i
          | i < picx = wrap160 (i+160)
          | i >= picx+160 = wrap160 (i-160)

{- INLINE stellaHmove -}
stellaHmove :: (MonadIO m, MonadState Stella m) => m ()
stellaHmove = do
    poffset0 <- getORegister hmp0
    ppos0' <- use ppos0
    ppos0 .= wrap160 (ppos0'-clockMove poffset0)

    poffset1 <- getORegister hmp1
    ppos1' <- use ppos1
    ppos1 .= wrap160 (ppos1'-clockMove poffset1)

    moffset0 <- getORegister hmm0
    mpos0' <- use mpos0
    mpos0 .= wrap160 (mpos0'-clockMove moffset0) -- XXX do rest

    moffset1 <- getORegister hmm1
    mpos1' <- use mpos1
    mpos1 .= wrap160 (mpos1'-clockMove moffset1) -- XXX do rest

    boffset <- getORegister hmbl
    bpos' <- use bpos
    bpos .= wrap160 (bpos'-clockMove boffset)

{- INLINE stellaResmp0 -}
stellaResmp0 :: (MonadIO m, MonadState Stella m) => m ()
stellaResmp0 = use ppos0 >>= (mpos0 .=) -- XXX

{- INLINE stellaResmp1 -}
stellaResmp1 :: (MonadIO m, MonadState Stella m) => m ()
stellaResmp1 = use ppos1 >>= (mpos1 .=) -- XXX

{- INLINE stellaWsync -}
stellaWsync :: (MonadIO m, MonadState Stella m) => m ()
stellaWsync = do
    hpos' <- use hpos
    --stellaTick (233-fromIntegral hpos') -- 228
    stellaTick (228-fromIntegral hpos') 

-- http://atariage.com/forums/topic/107527-atari-2600-vsyncvblank/

xscale, yscale :: CInt
xscale = 5
yscale = 3

renderDisplay :: StateT Stella IO ()
renderDisplay = do
    backSurface' <- use backSurface
    frontSurface' <- use frontSurface
    window' <- use frontWindow
    liftIO $ unlockSurface backSurface'
    liftIO $ SDL.surfaceBlitScaled backSurface' Nothing frontSurface'
                (Just (Rectangle (P (V2 0 0))
                    (V2 (screenWidth*xscale) (screenHeight*yscale))))
    liftIO $ lockSurface backSurface'
    liftIO $ SDL.updateWindowSurface window'

{- INLINE stellaVsync -}
stellaVsync :: Word8 -> StateT Stella IO ()
stellaVsync v = do
    stellaDebugStrLn 0 $ "VSYNC " ++ showHex v ""
    oldv <- getORegister vsync
    when (testBit oldv 1 && not (testBit v 1)) $ do
            hpos .= 0
            vpos .= 0
    putORegister vsync v
    renderDisplay

{- INLINE stellaVblank -}
stellaVblank :: (MonadIO m, MonadState Stella m) => Word8 -> m ()
stellaVblank v = do
    stellaDebugStrLn 0 $ "VBLANK " ++ showHex v ""
    vold <- use vblank
    -- Set latches for INPT4 and INPT5
    when (testBit v 6) $ do
        i <- getIRegister inpt4 -- XXX write modifyIRegister
        putIRegister inpt4 (setBit i 7)
        i <- getIRegister inpt5
        putIRegister inpt5 (setBit i 7)

    vblank .= v

-- player0

picy :: CInt
picy = 40
picx :: CInt
picx = 68

data Pixel = Pixel { plogic :: !Bool, pcolor :: !Word8 }

instance Monoid Pixel where
    {-# INLINE mappend #-}
    mempty = Pixel False 0
    _ `mappend` pixel@(Pixel True _) = pixel
    pixel `mappend` (Pixel False _) = pixel

bit :: Int -> Bool -> Word8
bit n t = if t then 1 `shift` n else 0

{- INLINE compositeAndCollide -}
compositeAndCollide :: (MonadIO m, MonadState Stella m) => CInt -> m Word8
compositeAndCollide x = do
    ctrlpf' <- getORegister ctrlpf
    colupf' <- getORegister colupf
    colup0' <- getORegister colup0
    colup1' <- getORegister colup1
    let playfieldColour = if testBit ctrlpf' 1
            then if x < 80
                then colup0'
                else colup1'
            else colupf'

    -- Assemble colours
    pbackground <- Pixel True <$> getORegister colubk
    pplayfield <- Pixel <$> playfield (fromIntegral $ x `div` 4) <*> return playfieldColour
    pplayer0 <- Pixel <$> player0 <*> return colup0'
    pplayer1 <- Pixel <$> player1 <*> return colup1'
    pmissile0 <- Pixel <$> missile0 <*> return colup0'
    pmissile1 <- Pixel <$> missile1 <*> return colup1'
    pball <- Pixel <$> ball <*> getORegister colupf

    let lmissile0 = plogic pmissile0
    let lmissile1 = plogic pmissile1
    let lplayer0 = plogic pplayer0
    let lplayer1 = plogic pplayer1
    let lball = plogic pball
    let lplayfield = plogic pplayfield

    orIRegister cxm0p $ bit 7 (lmissile0 && lplayer1) .|.  bit 6 (lmissile0 && lplayer0)
    orIRegister cxm1p $ bit 7 (lmissile1 && lplayer0) .|.  bit 6 (lmissile1 && lplayer1)
    orIRegister cxp0fb $ bit 7 (lplayer0 && lplayfield) .|.  bit 6 (lplayer0 && lball)
    orIRegister cxp1fb $ bit 7 (lplayer1 && lplayfield) .|.  bit 6 (lplayer1 && lball)
    orIRegister cxm0fb $ bit 7 (lmissile0 && lplayfield) .|.  bit 6 (lmissile0 && lball)
    orIRegister cxm1fb $ bit 7 (lmissile1 && lplayfield) .|.  bit 6 (lmissile1 && lball)
    orIRegister cxblpf $ bit 7 (lball && lplayfield)
    orIRegister cxppmm $ bit 7 (lplayer0 && lplayer1) .|.  bit 6 (lmissile0 && lmissile1)

    -- Get ordering priority
    let Pixel _ final = pbackground `mappend`
                        if testBit ctrlpf' 2
                            --then mconcat [pplayer1, pmissile1, pplayer0, pmissile0, pplayfield, pball]
                            ----else mconcat [pball, pplayfield, pplayer1, pmissile1, pplayer0, pmissile0]
                            then pplayer1 `mappend` pmissile1 `mappend` pplayer0 `mappend` pmissile0 `mappend` pplayfield `mappend` pball
                            else pball `mappend` pplayfield `mappend` pplayer1 `mappend` pmissile1 `mappend` pplayer0 `mappend` pmissile0
    return final

{-# INLINABLE timerTick #-}
timerTick :: IntervalTimer -> IntervalTimer
timerTick timer =
    let subtimer' = timer ^. subtimer
        subtimer'' = subtimer'-1
    in if subtimer' /= 0
        then timer & subtimer .~ subtimer''
        else
            let intim' = timer ^. intim
                intim'' = intim'-1
                interval' = timer ^. interval
            in if intim' /= 0
                then timer & intim .~ intim'' & subtimer .~ (3*interval'-1) 
                else IntervalTimer intim'' (3*1-1) 1

{-# INLINABLE updatePos #-}
updatePos :: (CInt, CInt) -> (CInt, CInt)
updatePos (hpos, vpos) =
    let hpos' = hpos+1
    in if hpos' < picx+160
        then (hpos', vpos)
        else let vpos' = vpos+1
             in if vpos' < picy+192
                then (0, vpos')
                else (0, 0)

stellaTick :: (MonadIO m, MonadState Stella m) => Int -> m ()
stellaTick 0 = return ()
stellaTick n = do
    xbreak' <- use (stellaDebug . xbreak)
    ybreak' <- use (stellaDebug . ybreak)
    hpos' <- use hpos
    vpos' <- use (vpos)
    when (hpos' == fromIntegral xbreak' && vpos' == fromIntegral ybreak') $ do
        dumpStella
        stellaDebug . xbreak .= (-1)
        stellaDebug . ybreak .= (-1)

    nowClock += 1

    -- Interval timer
    oldIntervalTimer <- use intervalTimer
    let newIntervalTimer = timerTick oldIntervalTimer
    intervalTimer .= newIntervalTimer
    
    -- Display
    when (vpos' >= picy && vpos' < picy+192 && hpos' >= picx) $ do
        surface <- use backSurface
        ptr <- liftIO $ surfacePixels surface
        let ptr' = castPtr ptr :: Ptr Word32
        let x = hpos'-picx
        let y = vpos'-picy
        let i = screenWidth*y+x

        final <- compositeAndCollide x

        liftIO $ pokeElemOff ptr' (fromIntegral i) (lut!(final `shift` (-1)))

    position' <- use position
    let position'' = updatePos position'
    position .= position''

    stellaTick (n-1)

data Registers = R {
    _pc :: !Word16,
    _p :: !Word8,
    _a :: !Word8,
    _x :: !Word8,
    _y :: !Word8,
    _s :: !Word8
}

$(makeLenses ''Registers)

{-# INLINE flagC #-}
flagC :: Lens' Registers Bool
flagC = p . bitAt 0

{-# INLINE flagZ #-}
flagZ :: Lens' Registers Bool
flagZ = p . bitAt 1

{-# INLINE flagI #-}
flagI :: Lens' Registers Bool
flagI = p . bitAt 2

{-# INLINE flagD #-}
flagD :: Lens' Registers Bool
flagD = p . bitAt 3

{-# INLINE flagB #-}
flagB :: Lens' Registers Bool
flagB = p . bitAt 4

{-# INLINE flagV #-}
flagV :: Lens' Registers Bool
flagV = p . bitAt 6

{-# INLINE flagN #-}
flagN :: Lens' Registers Bool
flagN = p . bitAt 7

data StateAtari = S {
    _stella :: Stella,
    _mem :: IOUArray Int Word8,
    _regs :: !Registers,
    _clock :: !Int,
    _debug :: !Int
}

makeLenses ''StateAtari

newtype MonadAtari a = M { unM :: StateT StateAtari IO a }
    deriving (Functor, Applicative, Monad, MonadState StateAtari, MonadIO)

--  XXX Do this! If reset occurs during horizontal blank, the object will appear at the left side of the television screen

{- INLINE setBreak -}
setBreak :: (MonadIO m, MonadState Stella m) =>
               Int32 -> Int32 -> m ()
setBreak x y = do
    stellaDebug . xbreak .= x+fromIntegral picx
    stellaDebug . ybreak .= y+fromIntegral picy

{-# INLINE usingStella #-}
usingStella :: StateT Stella IO a -> MonadAtari a
usingStella m = do
    stella' <- use stella
    (a, stella'') <- liftIO $ flip runStateT stella' m
    stella .= stella''
    return a

{- INLINABLE writeStella -}
writeStella :: Word16 -> Word8 -> StateT Stella IO ()
writeStella addr v = 
    case addr of
       0x00 -> stellaVsync v             -- VSYNC
       0x01 -> stellaVblank v            -- VBLANK
       0x02 -> stellaWsync               -- WSYNC
       0x04 -> putORegister nusiz0 v        -- NUSIZ0
       0x05 -> putORegister nusiz1 v        -- NUSIZ1
       0x06 -> putORegister colup0 v               -- COLUP0
       0x07 -> putORegister colup1 v               -- COLUP1
       0x08 -> putORegister colupf v               -- COLUPF
       0x09 -> putORegister colubk v               -- COLUBK
       0x0a -> putORegister ctrlpf v               -- COLUPF
       0x0b -> putORegister refp0 v               -- REFP0
       0x0c -> putORegister refp1 v               -- REFP1
       0x0d -> putORegister pf0 v                  -- PF0
       0x0e -> putORegister pf1 v                  -- PF1
       0x0f -> putORegister pf2 v                  -- PF2
       0x10 -> use hpos >>= ((ppos0 .=) . (+5))   -- RESP0
       0x11 -> use hpos >>= ((ppos1 .=) . (+5))   -- RESP1
       0x12 -> use hpos >>= (mpos0 .=) . (+4)   -- RESM0
       0x13 -> use hpos >>= (mpos1 .=) . (+4)   -- RESM1
       0x14 -> use hpos >>= (bpos .=) . (+4)    -- RESBL
       0x1b -> do -- GRP0
                graphics . newGrp0 .= v
                use (graphics . newGrp1) >>= (graphics . oldGrp1 .=)
       0x1c -> do -- GRP1
                graphics . newGrp1 .= v
                use (graphics . newGrp0) >>= (graphics . oldGrp0 .=)
                use (graphics . newBall) >>= (graphics . oldBall .=)
       0x1d -> putORegister enam0 v                -- ENAM0
       0x1e -> putORegister enam1 v                -- ENAM1
       0x1f -> graphics . newBall .= testBit v 1   -- ENABL
       0x20 -> putORegister hmp0 v                 -- HMP0
       0x21 -> putORegister hmp1 v                 -- HMP1
       0x22 -> putORegister hmm0 v                 -- HMM0
       0x23 -> putORegister hmm1 v                 -- HMM1
       0x24 -> putORegister hmbl v                 -- HMBL
       0x25 -> graphics . delayP0 .= testBit v 0   -- VDELP0
       0x26 -> graphics . delayP1 .= testBit v 0   -- VDELP1
       0x27 -> graphics . delayBall .= testBit v 0   -- VDELBL
       0x28 -> putORegister resmp0 v
       0x29 -> putORegister resmp1 v
       0x2a -> stellaHmove               -- HMOVE
       0x2b -> stellaHmclr               -- HMCLR
       0x2c -> stellaCxclr               -- CXCLR
       -- XXX rewrite properly
       0x294 -> do                       -- TIM1T
        intervalTimer . interval .= 1
        intervalTimer . subtimer .= 1*3-1
        intervalTimer . intim .= v
       0x295 -> do                       -- TIM8T
        intervalTimer . interval .= 8
        intervalTimer . subtimer .= 8*3-1
        intervalTimer . intim .= v
       0x296 -> do                       -- TIM64T
        intervalTimer . interval .= 64
        intervalTimer . subtimer .= 64*3-1
        intervalTimer . intim .= v
       0x297 -> do                       -- TIM1024T
        intervalTimer . interval .= 1024
        intervalTimer . subtimer .= 1024*3-1
        intervalTimer . intim .= v
       otherwise -> return () -- liftIO $ putStrLn $ "writing TIA 0x" ++ showHex addr ""

{- INLINABLE readStella -}
readStella :: (MonadIO m, MonadState Stella m) =>
              Word16 -> m Word8
readStella addr = 
    case addr of
        0x00 -> getIRegister cxm0p
        0x01 -> getIRegister cxm1p
        0x02 -> getIRegister cxp0fb
        0x03 -> getIRegister cxp1fb
        0x04 -> getIRegister cxm0fb
        0x05 -> getIRegister cxm1fb
        0x06 -> getIRegister cxblpf
        0x07 -> getIRegister cxppmm
        0x0c -> getIRegister inpt4
        0x10 -> getIRegister cxm0p
        0x11 -> getIRegister cxm1p
        0x12 -> getIRegister cxp0fb
        0x13 -> getIRegister cxp1fb
        0x14 -> getIRegister cxm0fb
        0x15 -> getIRegister cxm1fb
        0x16 -> getIRegister cxblpf
        0x17 -> getIRegister cxppmm
        0x1c -> getIRegister inpt4
        0x20 -> getIRegister cxm0p
        0x21 -> getIRegister cxm1p
        0x22 -> getIRegister cxp0fb
        0x23 -> getIRegister cxp1fb
        0x24 -> getIRegister cxm0fb
        0x25 -> getIRegister cxm1fb
        0x26 -> getIRegister cxblpf
        0x27 -> getIRegister cxppmm
        0x2c -> getIRegister inpt4
        0x30 -> getIRegister cxm0p
        0x31 -> getIRegister cxm1p
        0x32 -> getIRegister cxp0fb
        0x33 -> getIRegister cxp1fb
        0x34 -> getIRegister cxm0fb
        0x35 -> getIRegister cxm1fb
        0x36 -> getIRegister cxblpf
        0x37 -> getIRegister cxppmm
        0x3c -> getIRegister inpt4
        0x280 -> use swcha
        0x282 -> use swchb
        0x284 -> use (intervalTimer . intim)
        otherwise -> return 0 -- (liftIO $ putStrLn $ "reading TIA 0x" ++ showHex addr "") >> return 0

-- http://www.qotile.net/minidig/docs/2600_mem_map.txt

--
-- Decision tree for type of memory
--
-- testBit a 12
-- True -> ROM
-- False -> testBit a 7
--          False -> TIA
--          True -> testBit a 9
--                  True -> RIOT
--                  False -> RAM
{-# INLINE isTIA #-}
isTIA :: Word16 -> Bool
isTIA a = not (testBit a 7) && not (testBit a 12)

{-# INLINE isRAM #-}
isRAM :: Word16 -> Bool
isRAM a = testBit a 7 && not (testBit a 9) && not (testBit a 12)

{-# INLINE isRIOT #-}
isRIOT :: Word16 -> Bool
isRIOT a = testBit a 7 && testBit a 9 && not (testBit a 12)

{-# INLINE isROM #-}
isROM :: Word16 -> Bool
isROM a = testBit a 12

instance Emu6502 MonadAtari where
    {- INLINE readMemory -}
    readMemory addr' =
        let addr = addr' .&. 0b1111111111111 in -- 6507
            if isTIA addr
                then usingStella $ readStella (addr .&. 0x3f)
                else if isRAM addr
                        then do
                            m <- use mem
                            liftIO $ readArray m (iz addr .&. 0xff)
                        else if isRIOT addr
                            then usingStella $ readStella (0x280+(addr .&. 0x1f))
                            else if addr >= 0x1000
                                then do
                                    m <- use mem
                                    liftIO $ readArray m (iz addr)
                                else error $ "Mystery read from " ++ showHex addr ""


    {- INLINE writeMemory -}
    writeMemory addr' v =
        let addr = addr' .&. 0b1111111111111 in -- 6507
            if isTIA addr
                then usingStella $ writeStella (addr .&. 0x3f) v
                else if isRAM addr
                        then do
                            m <- use mem
                            liftIO $ writeArray m (iz addr .&. 0xff) v
                        else if isRIOT addr
                                then usingStella $ writeStella (0x280+(addr .&. 0x1f)) v
                                else if addr >= 0x1000
                                    then do
                                        m <- use mem
                                        liftIO $ writeArray m (iz addr) v
                                    else error $ "Mystery write to " ++ showHex addr ""

    {-# INLINE getPC #-}
    getPC = use (regs . pc)
    {-# INLINE tick #-}
    tick n = do
        clock += n
        usingStella $ stellaTick (3*n)
    {-# INLINE putC #-}
    putC b = regs . flagC .= b
    {-# INLINE getC #-}
    getC = use (regs . flagC)
    {-# INLINE putZ #-}
    putZ b = regs . flagZ .= b
    {-# INLINE getZ #-}
    getZ = use (regs . flagZ)
    {-# INLINE putI #-}
    putI b = regs . flagI .= b
    {-# INLINE getI #-}
    getI = use (regs . flagI)
    {-# INLINE putD #-}
    putD b = regs . flagD .= b
    {-# INLINE getD #-}
    getD = use (regs . flagD)
    {-# INLINE putB #-}
    putB b = regs . flagB .= b
    {-# INLINE getB #-}
    getB = use (regs . flagB)
    {-# INLINE putV #-}
    putV b = regs . flagV .= b
    {-# INLINE getV #-}
    getV = use (regs . flagV)
    {-# INLINE putN #-}
    putN b = regs . flagN .= b
    {-# INLINE getN #-}
    getN = use (regs . flagN)
    {-# INLINE getA #-}
    getA = use (regs . a)
    {-# INLINE putA #-}
    putA r = regs . a .= r
    {-# INLINE getS #-}
    getS = use (regs . s)
    {-# INLINE putS #-}
    putS r = regs . s .= r
    {-# INLINE getX #-}
    getX = use (regs . x)
    {-# INLINE putX #-}
    putX r = regs . x .= r
    {-# INLINE getP #-}
    getP = use (regs . p)
    {-# INLINE putP #-}
    putP r = regs . p .= r
    {-# INLINE getY #-}
    getY = use (regs . y)
    {-# INLINE putY #-}
    putY r = regs . y .= r
    {-# INLINE putPC #-}
    putPC r = regs . pc .= r
    {-# INLINE addPC #-}
    addPC n = regs . pc += fromIntegral n

    {- INLINE debugStr 9 -}
    debugStr n str = do
        d <- use debug
        if n <= d
            then liftIO $ putStr str
            else return ()

    {- INLINE debugStrLn 9 -}
    debugStrLn n str = do
        d <- use debug
        if n <= d
            then liftIO $ putStrLn str
            else return ()

    {- INLINE illegal -}
    illegal i = error $ "Illegal opcode 0x" ++ showHex i ""

data Args = Args { file :: String } deriving (Show, Data, Typeable)

clargs :: Args
clargs = Args { file = "adventure.bin" }

times :: (Integral n, Monad m) => n -> m a -> m ()
times 0 _ = return ()
times n m = m >> times (n-1) m

{- INLINE isPressed -}
isPressed :: InputMotion -> Bool
isPressed Pressed = True
isPressed Released = False

handleEvent :: Event -> MonadAtari ()
handleEvent event =
    case eventPayload event of
        MouseButtonEvent
            (MouseButtonEventData win Pressed device ButtonLeft clicks pos) -> do
            liftIO $ print pos
            let P (V2 x y) = pos
            usingStella $ setBreak (x `div` fromIntegral xscale) (y `div` fromIntegral yscale)
        MouseMotionEvent
            (MouseMotionEventData win device [ButtonLeft] pos rel) -> do
            liftIO $ print pos
            let P (V2 x y) = pos
            usingStella $ setBreak (x `div` fromIntegral xscale) (y `div` fromIntegral yscale)
        KeyboardEvent
            (KeyboardEventData win motion rep sym) -> do
            handleKey motion sym

        otherwise -> return ()

handleKey :: InputMotion -> Keysym -> MonadAtari ()
handleKey motion sym =
    let pressed = isPressed motion
    in case keysymScancode sym of
        SDL.Scancode1 -> dumpState
        SDL.ScancodeUp -> usingStella $ swcha . bitAt 4 .= not pressed
        SDL.ScancodeDown -> usingStella $ swcha . bitAt 5 .= not pressed
        SDL.ScancodeLeft -> usingStella $ swcha . bitAt 6 .= not pressed
        SDL.ScancodeRight -> usingStella $ swcha . bitAt 7 .= not pressed
        SDL.ScancodeC -> usingStella $ swchb . bitAt 1 .= not pressed
        SDL.ScancodeV -> usingStella $ swchb . bitAt 0 .= not pressed
        SDL.ScancodeSpace -> usingStella $ do
            latch <- use (vblank . bitAt 6)
            case (latch, pressed) of
                (False, _) -> do
                    inpt4' <- getIRegister inpt4
                    putIRegister inpt4 ((clearBit inpt4' 7) .|. bit 7 (not pressed))
                (True, False) -> return ()
                (True, True) -> do
                    inpt4' <- getIRegister inpt4
                    putIRegister inpt4 (clearBit inpt4' 7)
        SDL.ScancodeEscape -> liftIO $ exitSuccess
        otherwise -> return ()

initState :: IOUArray OReg Word8 ->
             IOUArray IReg Word8 ->
             Surface -> Surface ->
             SDL.Window -> Stella
initState oregs iregs helloWorld screenSurface window = Stella {
      _oregisters = oregs,
      _iregisters = iregs,
      _position = (0, 0),
      _backSurface = helloWorld,
      _frontSurface = screenSurface,
      _frontWindow = window,
      _vblank = 0,
      _sprites = Sprites {
          _s_ppos0 = 9999,
          _s_ppos1 = 9999,
          _s_mpos0 = 0,
          _s_mpos1 = 0,
          _s_bpos = 0
      },
      _swcha = 0xff,
      _swchb = 0b00001011,
      _intervalTimer = IntervalTimer {
          _intim = 0,
          _subtimer = 0,
          _interval = 0
      },
      _graphics = Graphics {
          _delayP0 = False,
          _delayP1 = False,
          _delayBall = False,
          _oldGrp0 = 0,
          _newGrp0 = 0,
          _oldGrp1 = 0,
          _newGrp1 = 0,
          _oldBall = False,
          _newBall = False
      },
      _stellaClock = Clock {
          _now = 0,
          _last = 0
      },
      _stellaDebug = Debug {
          _debugLevel = -1,
          _xbreak = -1,
          _ybreak = -1
      }
  }

main :: IO ()
main = do
  args <- cmdArgs clargs
  SDL.initialize [SDL.InitVideo]
  window <- SDL.createWindow "Stellarator" SDL.defaultWindow { SDL.windowInitialSize = V2 (xscale*screenWidth) (yscale*screenHeight) }
  SDL.showWindow window
  screenSurface <- SDL.getWindowSurface window

  helloWorld <- createRGBSurface (V2 screenWidth screenHeight) RGB888

  memory <- newArray (0, 0x2000) 0 :: IO (IOUArray Int Word8)
  readBinary memory (file args) 0x1000
  pclo <- readArray memory 0x1ffc
  pchi <- readArray memory 0x1ffd
  let initialPC = fromIntegral pclo+(fromIntegral pchi `shift` 8)

  oregs <- newArray (0, 0x3f) 0
  iregs <- newArray (0, 0x0d) 0
  let stella = initState oregs iregs helloWorld screenSurface window
  let state = S { _mem = memory,  _clock = 0, _regs = R initialPC 0 0 0 0 0xff,
                   _debug = 8,
                   _stella = stella}

  let loopUntil n = do
        stellaClock' <- usingStella $ use nowClock
        when (stellaClock' < n) $ do
            step
            loopUntil n

  --SDL.setHintWithPriority SDL.NormalPriority SDL.HintRenderVSync SDL.EnableVSync
  -- https://hackage.haskell.org/package/sdl2-2.1.3

  let loop = do
        events <- liftIO $ SDL.pollEvents

        let quit = elem SDL.QuitEvent $ map SDL.eventPayload events
        forM_ events handleEvent
        stellaClock' <- usingStella $ use nowClock
        loopUntil (stellaClock' + 10000)

        loop

  flip runStateT state $ unM $ do
    -- Joystick buttons not pressed
    usingStella $ putIRegister inpt4 0x80
    usingStella $ putIRegister inpt5 0x80
    loop

  SDL.destroyWindow window
  SDL.freeSurface helloWorld
  SDL.quit
