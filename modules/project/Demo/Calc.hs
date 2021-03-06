-- | Calculator based on http://trelford.com/PitCalculatorApp.htm

{-# LANGUAGE EmptyDataDecls #-}

module Demo.Calc where

import Language.Fay.FFI
import Language.Fay.Prelude

main :: Fay ()
main = do
  display <- select "<input type='text' value='' style='text-align:right'>"
  operation <- newRef Nothing
  appendMore <- newRef False

  let buttons =
        [[enter 7, enter 8, enter 9, ("/",operator (/))]
        ,[enter 4, enter 5, enter 6, ("*",operator (*))]
        ,[enter 1, enter 2, enter 3, ("-",operator (-))]
        ,[("C",clear), enter 0, ("=",calculate), ("+",operator (+))]]
      enter n = (show n,do current <- getVal display
                           addit <- readRef appendMore
                           if addit
                              then do setVal (current ++ show n) display
                                      return ()
                              else do setVal (show n) display
                                      writeRef appendMore True)
      getInput = getVal display >>= return . parseDouble 10
      operator op = do
        calculate
        num <- getInput
        writeRef operation (Just (op num))
      clear = do
        setVal "0" display
        writeRef operation Nothing
        calculate
      calculate = do
        op <- readRef operation
        case op of
          Nothing -> return ()
          Just maths -> do
            num <- getInput
            setVal (show (maths num)) display
            return ()
        writeRef operation Nothing
        writeRef appendMore False

  ready $ do
    body <- select "body"
    table <- select "<table></table>" & appendTo body
    dtr <- select "<tr></tr>" & appendTo table
    select "<td colspan='4'></td>" & appendTo dtr & append display
    forM_ buttons $ \row -> do
      tr <- select "<tr></tr>" & appendTo table
      forM_ row $ \(text,action) -> do
        td <- select "<td></td>" & appendTo tr
        select "<input type='button' value='' style='width:32px'>"
              & setVal text
              & appendTo td
              & onClick (do action; return False)

--------------------------------------------------------------------------------
-- JQuery bindings
-- These are provided in the fay-jquery package.

data JQuery
instance Foreign JQuery
instance Show JQuery

data Element
instance Foreign Element

-- | Nicer/easier binding for >>=.
(&) :: Fay a -> (a -> Fay b) -> Fay b
x & y = x >>= y
infixl 1 &

getVal :: JQuery -> Fay String
getVal = ffi "%1['val']()"

setVal :: String -> JQuery -> Fay JQuery
setVal = ffi "%2['val'](%1)"

select :: String -> Fay JQuery
select = ffi "window['jQuery'](%1)"

ready :: Fay () -> Fay ()
ready = ffi "window['jQuery'](%1)"

append :: JQuery -> JQuery -> Fay JQuery
append = ffi "%2['append'](%1)"

appendTo :: JQuery -> JQuery -> Fay JQuery
appendTo = ffi "%2['appendTo'](%1)"

onClick :: Fay Bool -> JQuery -> Fay JQuery
onClick = ffi "%2['click'](%1)"

--------------------------------------------------------------------------------
-- Utilities

instance (Foreign a) => Foreign (Maybe a)

parseDouble :: Int -> String -> Double
parseDouble = ffi "parseFloat(%2,%1) || 0"

--------------------------------------------------------------------------------
-- Refs
-- This will be provided in the fay package by default.

data Ref a
instance Show (Ref a)
instance Foreign a => Foreign (Ref a)

newRef :: Foreign a => a -> Fay (Ref a)
newRef = ffi "new Fay$$Ref(%1)"

writeRef :: Foreign a => Ref a -> a -> Fay ()
writeRef = ffi "Fay$$writeRef(%1,%2)"

readRef :: Foreign a => Ref a -> Fay a
readRef = ffi "Fay$$readRef(%1)"
