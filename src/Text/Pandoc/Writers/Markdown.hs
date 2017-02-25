{-# LANGUAGE OverloadedStrings, TupleSections, ScopedTypeVariables, MultiWayIf #-}
{-
Copyright (C) 2006-2015 John MacFarlane <jgm@berkeley.edu>

This program is free software; you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation; either version 2 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program; if not, write to the Free Software
Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
-}

{- |
   Module      : Text.Pandoc.Writers.Markdown
   Copyright   : Copyright (C) 2006-2015 John MacFarlane
   License     : GNU GPL, version 2 or above

   Maintainer  : John MacFarlane <jgm@berkeley.edu>
   Stability   : alpha
   Portability : portable

Conversion of 'Pandoc' documents to markdown-formatted plain text.

Markdown:  <http://daringfireball.net/projects/markdown/>
-}
module Text.Pandoc.Writers.Markdown (writeMarkdown, writePlain) where
import Text.Pandoc.Definition
import Text.Pandoc.Walk
import Text.Pandoc.Templates (renderTemplate')
import Text.Pandoc.Shared
import Text.Pandoc.Writers.Shared
import Text.Pandoc.Options
import Text.Pandoc.Parsing hiding (blankline, blanklines, char, space)
import Data.Maybe (fromMaybe)
import Data.Monoid (Any(..))
import Data.List ( group, stripPrefix, find, intersperse, transpose, sortBy )
import Data.Char ( isSpace, isPunctuation, ord, chr )
import Data.Ord ( comparing )
import Text.Pandoc.Pretty
import Control.Monad.Reader
import Control.Monad.State
import Control.Monad.Except (throwError)
import Text.Pandoc.Writers.HTML (writeHtml5String)
import Text.Pandoc.Writers.Math (texMathToInlines)
import Text.HTML.TagSoup (parseTags, isTagText, Tag(..))
import Network.URI (isURI)
import Data.Default
import Data.Yaml (Value(Object,String,Array,Bool,Number))
import qualified Data.HashMap.Strict as H
import qualified Data.Vector as V
import qualified Data.Text as T
import qualified Data.Set as Set
import Network.HTTP ( urlEncode )
import Text.Pandoc.Error
import Text.Pandoc.Class (PandocMonad, report)
import Text.Pandoc.Logging

type Notes = [[Block]]
type Ref   = ([Inline], Target, Attr)
type Refs  = [Ref]

type MD m = ReaderT WriterEnv (StateT WriterState m)

evalMD :: PandocMonad m => MD m a -> WriterEnv -> WriterState -> m a
evalMD md env st = evalStateT (runReaderT md env) st

data WriterEnv = WriterEnv { envInList         :: Bool
                           , envPlain          :: Bool
                           , envRefShortcutable :: Bool
                           , envBlockLevel      :: Int
                           , envEscapeSpaces   :: Bool
                           }

instance Default WriterEnv
  where def = WriterEnv { envInList         = False
                        , envPlain          = False
                        , envRefShortcutable = True
                        , envBlockLevel      = 0
                        , envEscapeSpaces    = False
                        }

data WriterState = WriterState { stNotes :: Notes
                               , stRefs  :: Refs
                               , stIds   :: Set.Set String
                               , stNoteNum :: Int
                               }

instance Default WriterState
  where def = WriterState{ stNotes = []
                         , stRefs = []
                         , stIds = Set.empty
                         , stNoteNum = 1
                         }

-- | Convert Pandoc to Markdown.
writeMarkdown :: PandocMonad m => WriterOptions -> Pandoc -> m String
writeMarkdown opts document =
  evalMD (pandocToMarkdown opts{
             writerWrapText = if isEnabled Ext_hard_line_breaks opts
                              then WrapNone
                              else writerWrapText opts }
             document) def def

-- | Convert Pandoc to plain text (like markdown, but without links,
-- pictures, or inline formatting).
writePlain :: PandocMonad m => WriterOptions -> Pandoc -> m String
writePlain opts document =
  evalMD (pandocToMarkdown opts document) def{ envPlain = True } def

pandocTitleBlock :: Doc -> [Doc] -> Doc -> Doc
pandocTitleBlock tit auths dat =
  hang 2 (text "% ") tit <> cr <>
  hang 2 (text "% ") (vcat $ map nowrap auths) <> cr <>
  hang 2 (text "% ") dat <> cr

mmdTitleBlock :: Value -> Doc
mmdTitleBlock (Object hashmap) =
  vcat $ map go $ sortBy (comparing fst) $ H.toList hashmap
  where go (k,v) =
          case (text (T.unpack k), v) of
               (k', Array vec)
                 | V.null vec     -> empty
                 | otherwise      -> k' <> ":" <> space <>
                                      hcat (intersperse "; "
                                           (map fromstr $ V.toList vec))
               (_, String "")  -> empty
               (k', x)         -> k' <> ":" <> space <> nest 2 (fromstr x)
        fromstr (String s) = text (removeBlankLines $ T.unpack s)
        fromstr (Bool b)   = text (show b)
        fromstr (Number n) = text (show n)
        fromstr _          = empty
        -- blank lines not allowed in MMD metadata - we replace with .
        removeBlankLines   = trimr . unlines . map (\x ->
                               if all isSpace x then "." else x) . lines
mmdTitleBlock _ = empty

plainTitleBlock :: Doc -> [Doc] -> Doc -> Doc
plainTitleBlock tit auths dat =
  tit <> cr <>
  (hcat (intersperse (text "; ") auths)) <> cr <>
  dat <> cr

yamlMetadataBlock :: Value -> Doc
yamlMetadataBlock v = "---" $$ (jsonToYaml v) $$ "---"

jsonToYaml :: Value -> Doc
jsonToYaml (Object hashmap) =
  vcat $ map (\(k,v) ->
          case (text (T.unpack k), v, jsonToYaml v) of
               (k', Array vec, x)
                 | V.null vec     -> empty
                 | otherwise      -> (k' <> ":") $$ x
               (k', Object _, x)  -> (k' <> ":") $$ nest 2 x
               (_, String "", _)  -> empty
               (k', _, x)         -> k' <> ":" <> space <> hang 2 "" x)
       $ sortBy (comparing fst) $ H.toList hashmap
jsonToYaml (Array vec) =
  vcat $ map (\v -> hang 2 "- " (jsonToYaml v)) $ V.toList vec
jsonToYaml (String "") = empty
jsonToYaml (String s) =
  case T.unpack s of
     x | '\n' `elem` x -> hang 2 ("|" <> cr) $ text x
       | not (any isPunctuation x) -> text x
       | otherwise     -> text $ "'" ++ substitute "'" "''" x ++ "'"
jsonToYaml (Bool b) = text $ show b
jsonToYaml (Number n) = text $ show n
jsonToYaml _ = empty

-- | Return markdown representation of document.
pandocToMarkdown :: PandocMonad m => WriterOptions -> Pandoc -> MD m String
pandocToMarkdown opts (Pandoc meta blocks) = do
  let colwidth = if writerWrapText opts == WrapAuto
                    then Just $ writerColumns opts
                    else Nothing
  isPlain <- asks envPlain
  metadata <- metaToJSON'
               (fmap (render colwidth) . blockListToMarkdown opts)
               (fmap (render colwidth) . inlineListToMarkdown opts)
               meta
  let title' = maybe empty text $ getField "title" metadata
  let authors' = maybe [] (map text) $ getField "author" metadata
  let date' = maybe empty text $ getField "date" metadata
  let titleblock = case writerTemplate opts of
                        Just _ | isPlain ->
                                 plainTitleBlock title' authors' date'
                               | isEnabled Ext_yaml_metadata_block opts ->
                                   yamlMetadataBlock metadata
                               | isEnabled Ext_pandoc_title_block opts ->
                                   pandocTitleBlock title' authors' date'
                               | isEnabled Ext_mmd_title_block opts ->
                                   mmdTitleBlock metadata
                               | otherwise -> empty
                        Nothing -> empty
  let headerBlocks = filter isHeaderBlock blocks
  toc <- if writerTableOfContents opts
         then tableOfContents opts headerBlocks
         else return empty
  -- Strip off final 'references' header if markdown citations enabled
  let blocks' = if isEnabled Ext_citations opts
                   then case reverse blocks of
                             (Div (_,["references"],_) _):xs -> reverse xs
                             _ -> blocks
                   else blocks
  body <- blockListToMarkdown opts blocks'
  notesAndRefs' <- notesAndRefs opts
  let render' :: Doc -> String
      render' = render colwidth
  let main = render' $ body <> notesAndRefs'
  let context  = defField "toc" (render' toc)
               $ defField "body" main
               $ (if isNullMeta meta
                     then id
                     else defField "titleblock" (render' titleblock))
               $ addVariablesToJSON opts metadata
  case writerTemplate opts of
       Nothing  -> return main
       Just tpl -> return $ renderTemplate' tpl context

-- | Return markdown representation of reference key table.
refsToMarkdown :: PandocMonad m => WriterOptions -> Refs -> MD m Doc
refsToMarkdown opts refs = mapM (keyToMarkdown opts) refs >>= return . vcat

-- | Return markdown representation of a reference key.
keyToMarkdown :: PandocMonad m
              => WriterOptions
              -> Ref
              -> MD m Doc
keyToMarkdown opts (label, (src, tit), attr) = do
  label' <- inlineListToMarkdown opts label
  let tit' = if null tit
                then empty
                else space <> "\"" <> text tit <> "\""
  return $ nest 2 $ hang 2
            ("[" <> label' <> "]:" <> space) (text src <> tit')
            <> linkAttributes opts attr

-- | Return markdown representation of notes.
notesToMarkdown :: PandocMonad m => WriterOptions -> [[Block]] -> MD m Doc
notesToMarkdown opts notes = do
  n <- gets stNoteNum
  notes' <- mapM (\(num, note) -> noteToMarkdown opts num note) (zip [n..] notes)
  modify $ \st -> st { stNoteNum = stNoteNum st + length notes }
  return $ vsep notes'

-- | Return markdown representation of a note.
noteToMarkdown :: PandocMonad m => WriterOptions -> Int -> [Block] -> MD m Doc
noteToMarkdown opts num blocks = do
  contents  <- blockListToMarkdown opts blocks
  let num' = text $ writerIdentifierPrefix opts ++ show num
  let marker = if isEnabled Ext_footnotes opts
                  then text "[^" <> num' <> text "]:"
                  else text "[" <> num' <> text "]"
  let markerSize = 4 + offset num'
  let spacer = case writerTabStop opts - markerSize of
                     n | n > 0  -> text $ replicate n ' '
                     _          -> text " "
  return $ if isEnabled Ext_footnotes opts
              then hang (writerTabStop opts) (marker <> spacer) contents
              else marker <> spacer <> contents

-- | Escape special characters for Markdown.
escapeString :: WriterOptions -> String -> String
escapeString _  [] = []
escapeString opts (c:cs) =
  case c of
       '<'   -> "&lt;" ++ escapeString opts cs
       '>'   -> "&gt;" ++ escapeString opts cs
       _ | c `elem` ['\\','`','*','_','[',']','#'] ->
              '\\':c:escapeString opts cs
       '^' | isEnabled Ext_superscript opts -> '\\':'^':escapeString opts cs
       '~' | isEnabled Ext_subscript opts -> '\\':'~':escapeString opts cs
       '$' | isEnabled Ext_tex_math_dollars opts -> '\\':'$':escapeString opts cs
       '\'' | isEnabled Ext_smart opts -> '\\':'\'':escapeString opts cs
       '"' | isEnabled Ext_smart opts -> '\\':'"':escapeString opts cs
       '-' | isEnabled Ext_smart opts ->
              case cs of
                   '-':_ -> '\\':'-':escapeString opts cs
                   _ -> '-':escapeString opts cs
       '.' | isEnabled Ext_smart opts ->
              case cs of
                   '.':'.':rest -> '\\':'.':'.':'.':escapeString opts rest
                   _ -> '.':escapeString opts cs
       _ -> c : escapeString opts cs

-- | Construct table of contents from list of header blocks.
tableOfContents :: PandocMonad m => WriterOptions -> [Block] -> m Doc
tableOfContents opts headers =
  let contents = BulletList $ map (elementToListItem opts) $ hierarchicalize headers
  in  evalMD (blockToMarkdown opts contents) def def

-- | Converts an Element to a list item for a table of contents,
elementToListItem :: WriterOptions -> Element -> [Block]
elementToListItem opts (Sec lev _nums (ident,_,_) headerText subsecs)
  = Plain headerLink :
    [ BulletList (map (elementToListItem opts) subsecs) |
      not (null subsecs) && lev < writerTOCDepth opts ]
   where headerLink = if null ident
                         then walk deNote headerText
                         else [Link nullAttr (walk deNote headerText)
                                 ('#':ident, "")]
elementToListItem _ (Blk _) = []

attrsToMarkdown :: Attr -> Doc
attrsToMarkdown attribs = braces $ hsep [attribId, attribClasses, attribKeys]
        where attribId = case attribs of
                                ([],_,_) -> empty
                                (i,_,_)  -> "#" <> text i
              attribClasses = case attribs of
                                (_,[],_) -> empty
                                (_,cs,_) -> hsep $
                                            map (text . ('.':))
                                            cs
              attribKeys = case attribs of
                                (_,_,[]) -> empty
                                (_,_,ks) -> hsep $
                                            map (\(k,v) -> text k
                                              <> "=\"" <> text v <> "\"") ks

linkAttributes :: WriterOptions -> Attr -> Doc
linkAttributes opts attr =
  if isEnabled Ext_link_attributes opts && attr /= nullAttr
     then attrsToMarkdown attr
     else empty

-- | Ordered list start parser for use in Para below.
olMarker :: Parser [Char] ParserState Char
olMarker = do (start, style', delim) <- anyOrderedListMarker
              if delim == Period &&
                          (style' == UpperAlpha || (style' == UpperRoman &&
                          start `elem` [1, 5, 10, 50, 100, 500, 1000]))
                          then spaceChar >> spaceChar
                          else spaceChar

-- | True if string begins with an ordered list marker
beginsWithOrderedListMarker :: String -> Bool
beginsWithOrderedListMarker str =
  case runParser olMarker defaultParserState "para start" (take 10 str) of
         Left  _  -> False
         Right _  -> True

notesAndRefs :: PandocMonad m => WriterOptions -> MD m Doc
notesAndRefs opts = do
  notes' <- reverse <$> gets stNotes >>= notesToMarkdown opts
  modify $ \s -> s { stNotes = [] }
  refs' <- reverse <$> gets stRefs >>= refsToMarkdown opts
  modify $ \s -> s { stRefs = [] }

  let endSpacing =
        if | writerReferenceLocation opts == EndOfDocument -> empty
           | isEmpty notes' && isEmpty refs' -> empty
           | otherwise -> blankline

  return $
    (if isEmpty notes' then empty else blankline <> notes') <>
    (if isEmpty refs' then empty else blankline <> refs') <>
    endSpacing

-- | Convert Pandoc block element to markdown.
blockToMarkdown :: PandocMonad m
                => WriterOptions -- ^ Options
                -> Block         -- ^ Block element
                -> MD m Doc
blockToMarkdown opts blk =
  local (\env -> env {envBlockLevel = envBlockLevel env + 1}) $
  do doc <- blockToMarkdown' opts blk
     blkLevel <- asks envBlockLevel
     if writerReferenceLocation opts == EndOfBlock && blkLevel == 1
       then notesAndRefs opts >>= (\d -> return $ doc <> d)
       else return doc

blockToMarkdown' :: PandocMonad m
                 => WriterOptions -- ^ Options
                 -> Block         -- ^ Block element
                 -> MD m Doc
blockToMarkdown' _ Null = return empty
blockToMarkdown' opts (Div attrs ils) = do
  contents <- blockListToMarkdown opts ils
  return $ if isEnabled Ext_raw_html opts &&
                isEnabled Ext_markdown_in_html_blocks opts
              then tagWithAttrs "div" attrs <> blankline <>
                      contents <> blankline <> "</div>" <> blankline
              else contents <> blankline
blockToMarkdown' opts (Plain inlines) = do
  contents <- inlineListToMarkdown opts inlines
  -- escape if para starts with ordered list marker
  isPlain <- asks envPlain
  let colwidth = if writerWrapText opts == WrapAuto
                    then Just $ writerColumns opts
                    else Nothing
  let rendered = render colwidth contents
  let escapeDelimiter (x:xs) | x `elem` (".()" :: String) = '\\':x:xs
                             | otherwise                  = x : escapeDelimiter xs
      escapeDelimiter []                                  = []
  let contents' = if isEnabled Ext_all_symbols_escapable opts &&
                     not isPlain && beginsWithOrderedListMarker rendered
                     then text $ escapeDelimiter rendered
                     else contents
  return $ contents' <> cr
-- title beginning with fig: indicates figure
blockToMarkdown' opts (Para [Image attr alt (src,'f':'i':'g':':':tit)]) =
  blockToMarkdown opts (Para [Image attr alt (src,tit)])
blockToMarkdown' opts (Para inlines) =
  (<> blankline) `fmap` blockToMarkdown opts (Plain inlines)
blockToMarkdown' opts (LineBlock lns) =
  if isEnabled Ext_line_blocks opts
  then do
    mdLines <- mapM (inlineListToMarkdown opts) lns
    return $ (vcat $ map (hang 2 (text "| ")) mdLines) <> blankline
  else blockToMarkdown opts $ linesToPara lns
blockToMarkdown' opts b@(RawBlock f str)
  | f == "markdown" = return $ text str <> text "\n"
  | f == "html" && isEnabled Ext_raw_html opts = do
    plain <- asks envPlain
    return $ if plain
                then empty
                else if isEnabled Ext_markdown_attribute opts
                        then text (addMarkdownAttribute str) <> text "\n"
                        else text str <> text "\n"
  | f `elem` ["latex", "tex"] && isEnabled Ext_raw_tex opts = do
    plain <- asks envPlain
    return $ if plain
                then empty
                else text str <> text "\n"
  | otherwise = do
      report $ BlockNotRendered b
      return empty
blockToMarkdown' opts HorizontalRule = do
  return $ blankline <> text (replicate (writerColumns opts) '-') <> blankline
blockToMarkdown' opts (Header level attr inlines) = do
  -- first, if we're putting references at the end of a section, we
  -- put them here.
  blkLevel <- asks envBlockLevel
  refs <- if writerReferenceLocation opts == EndOfSection && blkLevel == 1
          then notesAndRefs opts
          else return empty

  plain <- asks envPlain
  -- we calculate the id that would be used by auto_identifiers
  -- so we know whether to print an explicit identifier
  ids <- gets stIds
  let autoId = uniqueIdent inlines ids
  modify $ \st -> st{ stIds = Set.insert autoId ids }
  let attr' = case attr of
                   ("",[],[]) -> empty
                   (id',[],[]) | isEnabled Ext_auto_identifiers opts
                                 && id' == autoId -> empty
                   (id',_,_)   | isEnabled Ext_mmd_header_identifiers opts ->
                                    space <> brackets (text id')
                   _ | isEnabled Ext_header_attributes opts ->
                                    space <> attrsToMarkdown attr
                     | otherwise -> empty
  contents <- inlineListToMarkdown opts $
                 if level == 1 && plain
                    then capitalize inlines
                    else inlines
  let setext = writerSetextHeaders opts
      hdr = nowrap $ case level of
            1 | plain -> blanklines 3 <> contents <> blanklines 2
              | setext ->
                  contents <> attr' <> cr <> text (replicate (offset contents) '=') <>
                  blankline
            2 | plain -> blanklines 2 <> contents <> blankline
              | setext ->
                  contents <> attr' <> cr <> text (replicate (offset contents) '-') <>
                  blankline
            -- ghc interprets '#' characters in column 1 as linenum specifiers.
            _ | plain || isEnabled Ext_literate_haskell opts ->
                contents <> blankline
            _ -> text (replicate level '#') <> space <> contents <> attr' <> blankline

  return $ refs <> hdr
blockToMarkdown' opts (CodeBlock (_,classes,_) str)
  | "haskell" `elem` classes && "literate" `elem` classes &&
    isEnabled Ext_literate_haskell opts =
  return $ prefixed "> " (text str) <> blankline
blockToMarkdown' opts (CodeBlock attribs str) = return $
  case attribs == nullAttr of
     False | isEnabled Ext_backtick_code_blocks opts ->
          backticks <> attrs <> cr <> text str <> cr <> backticks <> blankline
           | isEnabled Ext_fenced_code_blocks opts ->
          tildes <> attrs <> cr <> text str <> cr <> tildes <> blankline
     _ -> nest (writerTabStop opts) (text str) <> blankline
   where tildes    = text $ case [ln | ln <- lines str, all (=='~') ln] of
                               [] -> "~~~~"
                               xs -> case maximum $ map length xs of
                                          n | n < 3 -> "~~~~"
                                            | otherwise -> replicate (n+1) '~'
         backticks = text $ case [ln | ln <- lines str, all (=='`') ln] of
                               [] -> "```"
                               xs -> case maximum $ map length xs of
                                          n | n < 3 -> "```"
                                            | otherwise -> replicate (n+1) '`'
         attrs  = if isEnabled Ext_fenced_code_attributes opts
                     then nowrap $ " " <> attrsToMarkdown attribs
                     else case attribs of
                                (_,(cls:_),_) -> " " <> text cls
                                _             -> empty
blockToMarkdown' opts (BlockQuote blocks) = do
  plain <- asks envPlain
  -- if we're writing literate haskell, put a space before the bird tracks
  -- so they won't be interpreted as lhs...
  let leader = if isEnabled Ext_literate_haskell opts
                  then " > "
                  else if plain then "  " else "> "
  contents <- blockListToMarkdown opts blocks
  return $ (prefixed leader contents) <> blankline
blockToMarkdown' opts t@(Table caption aligns widths headers rows) =  do
  caption' <- inlineListToMarkdown opts caption
  let caption'' = if null caption || not (isEnabled Ext_table_captions opts)
                     then empty
                     else blankline <> ": " <> caption' <> blankline
  rawHeaders <- mapM (blockListToMarkdown opts) headers
  rawRows <- mapM (mapM (blockListToMarkdown opts)) rows
  let isLineBreak LineBreak = Any True
      isLineBreak _         = Any False
  let isSimple = all (==0) widths &&
                 not ( getAny (query isLineBreak (headers:rows)) )
  let isPlainBlock (Plain _) = True
      isPlainBlock _         = False
  let hasBlocks = not (all isPlainBlock $ concat . concat $ headers:rows)
  (nst,tbl) <- case True of
                _ | isSimple &&
                    isEnabled Ext_simple_tables opts -> fmap (nest 2,) $
                         pandocTable opts (all null headers) aligns widths
                             rawHeaders rawRows
                  | isSimple &&
                    isEnabled Ext_pipe_tables opts -> fmap (id,) $
                         pipeTable (all null headers) aligns rawHeaders rawRows
                  | not hasBlocks &&
                    isEnabled Ext_multiline_tables opts -> fmap (nest 2,) $
                         pandocTable opts (all null headers) aligns widths
                             rawHeaders rawRows
                  | isEnabled Ext_grid_tables opts -> fmap (id,) $
                         gridTable opts (all null headers) aligns widths
                             rawHeaders rawRows
                  | isEnabled Ext_raw_html opts -> fmap (id,) $
                         text <$>
                         (writeHtml5String def $ Pandoc nullMeta [t])
                  | otherwise -> return $ (id, text "[TABLE]")
  return $ nst $ tbl $$ blankline $$ caption'' $$ blankline
blockToMarkdown' opts (BulletList items) = do
  contents <- inList $ mapM (bulletListItemToMarkdown opts) items
  return $ cat contents <> blankline
blockToMarkdown' opts (OrderedList (start,sty,delim) items) = do
  let start' = if isEnabled Ext_startnum opts then start else 1
  let sty'   = if isEnabled Ext_fancy_lists opts then sty else DefaultStyle
  let delim' = if isEnabled Ext_fancy_lists opts then delim else DefaultDelim
  let attribs = (start', sty', delim')
  let markers  = orderedListMarkers attribs
  let markers' = map (\m -> if length m < 3
                               then m ++ replicate (3 - length m) ' '
                               else m) markers
  contents <- inList $
              mapM (\(item, num) -> orderedListItemToMarkdown opts item num) $
              zip markers' items
  return $ cat contents <> blankline
blockToMarkdown' opts (DefinitionList items) = do
  contents <- inList $ mapM (definitionListItemToMarkdown opts) items
  return $ cat contents <> blankline

inList :: Monad m => MD m a -> MD m a
inList p = local (\env -> env {envInList = True}) p

addMarkdownAttribute :: String -> String
addMarkdownAttribute s =
  case span isTagText $ reverse $ parseTags s of
       (xs,(TagOpen t attrs:rest)) ->
            renderTags' $ reverse rest ++ (TagOpen t attrs' : reverse xs)
              where attrs' = ("markdown","1"):[(x,y) | (x,y) <- attrs,
                                 x /= "markdown"]
       _ -> s

pipeTable :: PandocMonad m => Bool -> [Alignment] -> [Doc] -> [[Doc]] -> MD m Doc
pipeTable headless aligns rawHeaders rawRows = do
  let sp = text " "
  let blockFor AlignLeft   x y = lblock (x + 2) (sp <> y) <> lblock 0 empty
      blockFor AlignCenter x y = cblock (x + 2) (sp <> y) <> lblock 0 empty
      blockFor AlignRight  x y = rblock (x + 2) (sp <> y) <> lblock 0 empty
      blockFor _           x y = lblock (x + 2) (sp <> y) <> lblock 0 empty
  let widths = map (max 3 . maximum . map offset) $ transpose (rawHeaders : rawRows)
  let torow cs = nowrap $ text "|" <>
                    hcat (intersperse (text "|") $
                          zipWith3 blockFor aligns widths (map chomp cs))
                    <> text "|"
  let toborder (a, w) = text $ case a of
                             AlignLeft    -> ':':replicate (w + 1) '-'
                             AlignCenter  -> ':':replicate w '-' ++ ":"
                             AlignRight   -> replicate (w + 1) '-' ++ ":"
                             AlignDefault -> replicate (w + 2) '-'
  -- note:  pipe tables can't completely lack a
  -- header; for a headerless table, we need a header of empty cells.
  -- see jgm/pandoc#1996.
  let header = if headless
                  then torow (replicate (length aligns) empty)
                  else torow rawHeaders
  let border = nowrap $ text "|" <> hcat (intersperse (text "|") $
                        map toborder $ zip aligns widths) <> text "|"
  let body   = vcat $ map torow rawRows
  return $ header $$ border $$ body

pandocTable :: PandocMonad m => WriterOptions -> Bool -> [Alignment] -> [Double]
            -> [Doc] -> [[Doc]] -> MD m Doc
pandocTable opts headless aligns widths rawHeaders rawRows = do
  let isSimple = all (==0) widths
  let alignHeader alignment = case alignment of
                                AlignLeft    -> lblock
                                AlignCenter  -> cblock
                                AlignRight   -> rblock
                                AlignDefault -> lblock
  -- Number of characters per column necessary to output every cell
  -- without requiring a line break.
  -- The @+2@ is needed for specifying the alignment.
  let numChars    = (+ 2) . maximum . map offset
  -- Number of characters per column necessary to output every cell
  -- without requiring a line break *inside a word*.
  -- The @+2@ is needed for specifying the alignment.
  let minNumChars = (+ 2) . maximum . map minOffset
  let columns = transpose (rawHeaders : rawRows)
  -- minimal column width without wrapping a single word
  let noWordWrapWidth
        | writerWrapText opts == WrapAuto
                              = fromIntegral $ maximum (map minNumChars columns)
        | otherwise           = fromIntegral $ maximum (map    numChars columns)
  let relWidth w = floor $ max (fromIntegral (writerColumns opts) * w)
                               (noWordWrapWidth * w / minimum widths)
  let widthsInChars
        | isSimple  = map numChars columns
        | otherwise = map relWidth widths
  let makeRow = hcat . intersperse (lblock 1 (text " ")) .
                   (zipWith3 alignHeader aligns widthsInChars)
  let rows' = map makeRow rawRows
  let head' = makeRow rawHeaders
  let maxRowHeight = maximum $ map height (head':rows')
  let underline = cat $ intersperse (text " ") $
                  map (\width -> text (replicate width '-')) widthsInChars
  let border = if maxRowHeight > 1
                  then text (replicate (sum widthsInChars +
                          length widthsInChars - 1) '-')
                  else if headless
                          then underline
                          else empty
  let head'' = if headless
                  then empty
                  else border <> cr <> head'
  let body = if maxRowHeight > 1
                then vsep rows'
                else vcat rows'
  let bottom = if headless
                  then underline
                  else border
  return $ head'' $$ underline $$ body $$ bottom

gridTable :: PandocMonad m => WriterOptions -> Bool -> [Alignment] -> [Double]
          -> [Doc] -> [[Doc]] -> MD m Doc
gridTable opts headless aligns widths headers' rawRows =  do
  let numcols = length headers'
  let widths' = if all (==0) widths
                   then replicate numcols (1.0 / fromIntegral numcols)
                   else widths
  let widthsInChars = map
         ((\x -> x - 3) . floor . (fromIntegral (writerColumns opts) *)) widths'
  let hpipeBlocks blocks = hcat [beg, middle, end]
        where h       = maximum (1 : map height blocks)
              sep'    = lblock 3 $ vcat (map text $ replicate h " | ")
              beg     = lblock 2 $ vcat (map text $ replicate h "| ")
              end     = lblock 2 $ vcat (map text $ replicate h " |")
              middle  = chomp $ hcat $ intersperse sep' blocks
  let makeRow = hpipeBlocks . zipWith lblock widthsInChars
  let head' = makeRow headers'
  let rows' = map (makeRow . map chomp) rawRows
  let borderpart ch align widthInChars =
        let widthInChars' = if widthInChars < 1 then 1 else widthInChars
        in (if (align == AlignLeft || align == AlignCenter)
               then char ':'
               else char ch) <>
           text (replicate widthInChars' ch) <>
           (if (align == AlignRight || align == AlignCenter)
               then char ':'
               else char ch)
  let border ch aligns' widthsInChars' =
        char '+' <>
        hcat (intersperse (char '+') (zipWith (borderpart ch)
                aligns' widthsInChars')) <> char '+'
  let body = vcat $ intersperse (border '-' (repeat AlignDefault) widthsInChars)
                    rows'
  let head'' = if headless
                  then empty
                  else head' $$ border '=' aligns widthsInChars
  if headless
     then return $
           border '-' aligns widthsInChars $$
           body $$
           border '-' (repeat AlignDefault) widthsInChars
     else return $
           border '-' (repeat AlignDefault) widthsInChars $$
           head'' $$
           body $$
           border '-' (repeat AlignDefault) widthsInChars

itemEndsWithTightList :: [Block] -> Bool
itemEndsWithTightList bs =
  case bs of
        [Plain _, BulletList xs]    -> isTightList xs
        [Plain _, OrderedList _ xs] -> isTightList xs
        _ -> False

-- | Convert bullet list item (list of blocks) to markdown.
bulletListItemToMarkdown :: PandocMonad m => WriterOptions -> [Block] -> MD m Doc
bulletListItemToMarkdown opts bs = do
  contents <- blockListToMarkdown opts bs
  let sps = replicate (writerTabStop opts - 2) ' '
  let start = text ('-' : ' ' : sps)
  -- remove trailing blank line if item ends with a tight list
  let contents' = if itemEndsWithTightList bs
                     then chomp contents <> cr
                     else contents
  return $ hang (writerTabStop opts) start $ contents' <> cr

-- | Convert ordered list item (a list of blocks) to markdown.
orderedListItemToMarkdown :: PandocMonad m
                          => WriterOptions -- ^ options
                          -> String        -- ^ list item marker
                          -> [Block]       -- ^ list item (list of blocks)
                          -> MD m Doc
orderedListItemToMarkdown opts marker bs = do
  contents <- blockListToMarkdown opts bs
  let sps = case length marker - writerTabStop opts of
                   n | n > 0 -> text $ replicate n ' '
                   _         -> text " "
  let start = text marker <> sps
  -- remove trailing blank line if item ends with a tight list
  let contents' = if itemEndsWithTightList bs
                     then chomp contents <> cr
                     else contents
  return $ hang (writerTabStop opts) start $ contents' <> cr

-- | Convert definition list item (label, list of blocks) to markdown.
definitionListItemToMarkdown :: PandocMonad m
                             => WriterOptions
                             -> ([Inline],[[Block]])
                             -> MD m Doc
definitionListItemToMarkdown opts (label, defs) = do
  labelText <- inlineListToMarkdown opts label
  defs' <- mapM (mapM (blockToMarkdown opts)) defs
  if isEnabled Ext_definition_lists opts
     then do
       let tabStop = writerTabStop opts
       isPlain <- asks envPlain
       let leader  = if isPlain then "   " else ":  "
       let sps = case writerTabStop opts - 3 of
                      n | n > 0   -> text $ replicate n ' '
                      _           -> text " "
       if isEnabled Ext_compact_definition_lists opts
          then do
            let contents = vcat $ map (\d -> hang tabStop (leader <> sps)
                                $ vcat d <> cr) defs'
            return $ nowrap labelText <> cr <> contents <> cr
          else do
            let contents = vcat $ map (\d -> hang tabStop (leader <> sps)
                                $ vcat d <> cr) defs'
            let isTight = case defs of
                               ((Plain _ : _): _) -> True
                               _ -> False
            return $ blankline <> nowrap labelText <>
                     (if isTight then cr else blankline) <> contents <> blankline
     else do
       return $ nowrap labelText <> text "  " <> cr <>
                vsep (map vsep defs') <> blankline

-- | Convert list of Pandoc block elements to markdown.
blockListToMarkdown :: PandocMonad m
                    => WriterOptions -- ^ Options
                    -> [Block]       -- ^ List of block elements
                    -> MD m Doc
blockListToMarkdown opts blocks =
  mapM (blockToMarkdown opts) (fixBlocks blocks) >>= return . cat
    -- insert comment between list and indented code block, or the
    -- code block will be treated as a list continuation paragraph
    where fixBlocks (b : CodeBlock attr x : rest)
            | (not (isEnabled Ext_fenced_code_blocks opts) || attr == nullAttr)
                && isListBlock b = b : commentSep : CodeBlock attr x :
                                   fixBlocks rest
          fixBlocks (b1@(BulletList _) : b2@(BulletList _) : bs) =
               b1 : commentSep : fixBlocks (b2:bs)
          fixBlocks (b1@(OrderedList _ _) : b2@(OrderedList _ _) : bs) =
               b1 : commentSep : fixBlocks (b2:bs)
          fixBlocks (b1@(DefinitionList _) : b2@(DefinitionList _) : bs) =
               b1 : commentSep : fixBlocks (b2:bs)
          fixBlocks (x : xs)             = x : fixBlocks xs
          fixBlocks []                   = []
          isListBlock (BulletList _)     = True
          isListBlock (OrderedList _ _)  = True
          isListBlock (DefinitionList _) = True
          isListBlock _                  = False
          commentSep                     = if isEnabled Ext_raw_html opts
                                              then RawBlock "html" "<!-- -->\n"
                                              else RawBlock "markdown" "&nbsp;"

-- | Get reference for target; if none exists, create unique one and return.
--   Prefer label if possible; otherwise, generate a unique key.
getReference :: PandocMonad m => Attr -> [Inline] -> Target -> MD m [Inline]
getReference attr label target = do
  st <- get
  case find (\(_,t,a) -> t == target && a == attr) (stRefs st) of
    Just (ref, _, _) -> return ref
    Nothing       -> do
      label' <- case find (\(l,_,_) -> l == label) (stRefs st) of
                  Just _ -> -- label is used; generate numerical label
                    case find (\n -> notElem [Str (show n)]
                                     (map (\(l,_,_) -> l) (stRefs st)))
                         [1..(10000 :: Integer)] of
                      Just x  -> return [Str (show x)]
                      Nothing -> throwError $ PandocSomeError "no unique label"
                  Nothing -> return label
      modify (\s -> s{ stRefs = (label', target, attr) : stRefs st })
      return label'

-- | Convert list of Pandoc inline elements to markdown.
inlineListToMarkdown :: PandocMonad m => WriterOptions -> [Inline] -> MD m Doc
inlineListToMarkdown opts lst = do
  inlist <- asks envInList
  go (if inlist then avoidBadWrapsInList lst else lst)
  where go [] = return empty
        go (i:is) = case i of
            (Link _ _ _) -> case is of
                -- If a link is followed by another link or '[' we don't shortcut
                (Link _ _ _):_                -> unshortcutable
                Space:(Link _ _ _):_          -> unshortcutable
                Space:(Str('[':_)):_          -> unshortcutable
                Space:(RawInline _ ('[':_)):_ -> unshortcutable
                Space:(Cite _ _):_            -> unshortcutable
                SoftBreak:(Link _ _ _):_      -> unshortcutable
                SoftBreak:(Str('[':_)):_      -> unshortcutable
                SoftBreak:(RawInline _ ('[':_)):_ -> unshortcutable
                SoftBreak:(Cite _ _):_        -> unshortcutable
                (Cite _ _):_                  -> unshortcutable
                Str ('[':_):_                 -> unshortcutable
                (RawInline _ ('[':_)):_       -> unshortcutable
                (RawInline _ (' ':'[':_)):_   -> unshortcutable
                _                             -> shortcutable
            _ -> shortcutable
          where shortcutable = liftM2 (<>) (inlineToMarkdown opts i) (go is)
                unshortcutable = do
                    iMark <- local
                             (\env -> env { envRefShortcutable = False })
                             (inlineToMarkdown opts i)
                    fmap (iMark <>) (go is)

isSp :: Inline -> Bool
isSp Space = True
isSp SoftBreak = True
isSp _ = False

avoidBadWrapsInList :: [Inline] -> [Inline]
avoidBadWrapsInList [] = []
avoidBadWrapsInList (s:Str ('>':cs):xs) | isSp s =
  Str (' ':'>':cs) : avoidBadWrapsInList xs
avoidBadWrapsInList (s:Str [c]:[])
  | isSp s && c `elem` ['-','*','+'] = Str [' ', c] : []
avoidBadWrapsInList (s:Str [c]:Space:xs)
  | isSp s && c `elem` ['-','*','+'] =
    Str [' ', c] : Space : avoidBadWrapsInList xs
avoidBadWrapsInList (s:Str cs:Space:xs)
  | isSp s && isOrderedListMarker cs =
    Str (' ':cs) : Space : avoidBadWrapsInList xs
avoidBadWrapsInList (s:Str cs:[])
  | isSp s && isOrderedListMarker cs = Str (' ':cs) : []
avoidBadWrapsInList (x:xs) = x : avoidBadWrapsInList xs

isOrderedListMarker :: String -> Bool
isOrderedListMarker xs = (last xs `elem` ['.',')']) &&
              isRight (runParser (anyOrderedListMarker >> eof)
                       defaultParserState "" xs)

isRight :: Either a b -> Bool
isRight (Right _) = True
isRight (Left  _) = False

-- | Convert Pandoc inline element to markdown.
inlineToMarkdown :: PandocMonad m => WriterOptions -> Inline -> MD m Doc
inlineToMarkdown opts (Span attrs ils) = do
  plain <- asks envPlain
  contents <- inlineListToMarkdown opts ils
  return $ case plain of
                True -> contents
                False | isEnabled Ext_bracketed_spans opts ->
                        "[" <> contents <> "]" <>
                          if attrs == nullAttr
                             then "{}"
                             else linkAttributes opts attrs
                      | isEnabled Ext_raw_html opts ||
                        isEnabled Ext_native_spans opts ->
                        tagWithAttrs "span" attrs <> contents <> text "</span>"
                      | otherwise -> contents
inlineToMarkdown opts (Emph lst) = do
  plain <- asks envPlain
  contents <- inlineListToMarkdown opts lst
  return $ if plain
              then "_" <> contents <> "_"
              else "*" <> contents <> "*"
inlineToMarkdown opts (Strong lst) = do
  plain <- asks envPlain
  if plain
     then inlineListToMarkdown opts $ capitalize lst
     else do
       contents <- inlineListToMarkdown opts lst
       return $ "**" <> contents <> "**"
inlineToMarkdown opts (Strikeout lst) = do
  contents <- inlineListToMarkdown opts lst
  return $ if isEnabled Ext_strikeout opts
              then "~~" <> contents <> "~~"
              else if isEnabled Ext_raw_html opts
                       then "<s>" <> contents <> "</s>"
                       else contents
inlineToMarkdown opts (Superscript lst) =
  local (\env -> env {envEscapeSpaces = True}) $ do
    contents <- inlineListToMarkdown opts lst
    return $ if isEnabled Ext_superscript opts
                then "^" <> contents <> "^"
                else if isEnabled Ext_raw_html opts
                         then "<sup>" <> contents <> "</sup>"
                         else case (render Nothing contents) of
                                   ds | all (\d -> d >= '0' && d <= '9') ds
                                     -> text (map toSuperscript ds)
                                   _ -> contents
                          where toSuperscript '1' = '\x00B9'
                                toSuperscript '2' = '\x00B2'
                                toSuperscript '3' = '\x00B3'
                                toSuperscript c = chr (0x2070 + (ord c - 48))
inlineToMarkdown opts (Subscript lst) =
  local (\env -> env {envEscapeSpaces = True}) $ do
    contents <- inlineListToMarkdown opts lst
    return $ if isEnabled Ext_subscript opts
                then "~" <> contents <> "~"
                else if isEnabled Ext_raw_html opts
                         then "<sub>" <> contents <> "</sub>"
                         else case (render Nothing contents) of
                                   ds | all (\d -> d >= '0' && d <= '9') ds
                                     -> text (map toSubscript ds)
                                   _ -> contents
                          where toSubscript c = chr (0x2080 + (ord c - 48))
inlineToMarkdown opts (SmallCaps lst) = do
  plain <- asks envPlain
  if not plain &&
     (isEnabled Ext_raw_html opts || isEnabled Ext_native_spans opts)
     then do
       contents <- inlineListToMarkdown opts lst
       return $ tagWithAttrs "span"
                 ("",[],[("style","font-variant:small-caps;")])
             <> contents <> text "</span>"
     else inlineListToMarkdown opts $ capitalize lst
inlineToMarkdown opts (Quoted SingleQuote lst) = do
  contents <- inlineListToMarkdown opts lst
  return $ if isEnabled Ext_smart opts
              then "'" <> contents <> "'"
              else "‘" <> contents <> "’"
inlineToMarkdown opts (Quoted DoubleQuote lst) = do
  contents <- inlineListToMarkdown opts lst
  return $ if isEnabled Ext_smart opts
              then "\"" <> contents <> "\""
              else "“" <> contents <> "”"
inlineToMarkdown opts (Code attr str) = do
  let tickGroups = filter (\s -> '`' `elem` s) $ group str
  let longest    = if null tickGroups
                     then 0
                     else maximum $ map length tickGroups
  let marker     = replicate (longest + 1) '`'
  let spacer     = if (longest == 0) then "" else " "
  let attrs      = if isEnabled Ext_inline_code_attributes opts && attr /= nullAttr
                      then attrsToMarkdown attr
                      else empty
  plain <- asks envPlain
  if plain
     then return $ text str
     else return $ text (marker ++ spacer ++ str ++ spacer ++ marker) <> attrs
inlineToMarkdown opts (Str str) = do
  isPlain <- asks envPlain
  let str' = (if isEnabled Ext_smart opts
                 then unsmartify opts
                 else id) $
              if isPlain
                 then str
                 else escapeString opts str
  return $ text str'
inlineToMarkdown opts (Math InlineMath str) =
  case writerHTMLMathMethod opts of
       WebTeX url ->
             inlineToMarkdown opts (Image nullAttr [Str str]
                 (url ++ urlEncode str, str))
       _ | isEnabled Ext_tex_math_dollars opts ->
             return $ "$" <> text str <> "$"
         | isEnabled Ext_tex_math_single_backslash opts ->
             return $ "\\(" <> text str <> "\\)"
         | isEnabled Ext_tex_math_double_backslash opts ->
             return $ "\\\\(" <> text str <> "\\\\)"
         | otherwise -> do
             plain <- asks envPlain
             texMathToInlines InlineMath str >>=
               inlineListToMarkdown opts .
                 (if plain then makeMathPlainer else id)
inlineToMarkdown opts (Math DisplayMath str) =
  case writerHTMLMathMethod opts of
      WebTeX url -> (\x -> blankline <> x <> blankline) `fmap`
             inlineToMarkdown opts (Image nullAttr [Str str]
                    (url ++ urlEncode str, str))
      _ | isEnabled Ext_tex_math_dollars opts ->
            return $ "$$" <> text str <> "$$"
        | isEnabled Ext_tex_math_single_backslash opts ->
            return $ "\\[" <> text str <> "\\]"
        | isEnabled Ext_tex_math_double_backslash opts ->
            return $ "\\\\[" <> text str <> "\\\\]"
        | otherwise -> (\x -> cr <> x <> cr) `fmap`
            (texMathToInlines DisplayMath str >>= inlineListToMarkdown opts)
inlineToMarkdown opts il@(RawInline f str) = do
  plain <- asks envPlain
  if not plain &&
     ( f == "markdown" ||
       (isEnabled Ext_raw_tex opts && (f == "latex" || f == "tex")) ||
       (isEnabled Ext_raw_html opts && f == "html") )
    then return $ text str
    else do
      report $ InlineNotRendered il
      return empty
inlineToMarkdown opts (LineBreak) = do
  plain <- asks envPlain
  if plain || isEnabled Ext_hard_line_breaks opts
     then return cr
     else return $
          if isEnabled Ext_escaped_line_breaks opts
             then "\\" <> cr
             else "  " <> cr
inlineToMarkdown _ Space = do
  escapeSpaces <- asks envEscapeSpaces
  return $ if escapeSpaces then "\\ " else space
inlineToMarkdown opts SoftBreak = do
  escapeSpaces <- asks envEscapeSpaces
  let space' = if escapeSpaces then "\\ " else space
  return $ case writerWrapText opts of
                WrapNone     -> space'
                WrapAuto     -> space'
                WrapPreserve -> cr
inlineToMarkdown opts (Cite [] lst) = inlineListToMarkdown opts lst
inlineToMarkdown opts (Cite (c:cs) lst)
  | not (isEnabled Ext_citations opts) = inlineListToMarkdown opts lst
  | otherwise =
      if citationMode c == AuthorInText
         then do
           suffs <- inlineListToMarkdown opts $ citationSuffix c
           rest <- mapM convertOne cs
           let inbr = suffs <+> joincits rest
               br   = if isEmpty inbr then empty else char '[' <> inbr <> char ']'
           return $ text ("@" ++ citationId c) <+> br
         else do
           cits <- mapM convertOne (c:cs)
           return $ text "[" <> joincits cits <> text "]"
  where
        joincits = hcat . intersperse (text "; ") . filter (not . isEmpty)
        convertOne Citation { citationId      = k
                            , citationPrefix  = pinlines
                            , citationSuffix  = sinlines
                            , citationMode    = m }
                               = do
           pdoc <- inlineListToMarkdown opts pinlines
           sdoc <- inlineListToMarkdown opts sinlines
           let k' = text (modekey m ++ "@" ++ k)
               r = case sinlines of
                        Str (y:_):_ | y `elem` (",;]@" :: String) -> k' <> sdoc
                        _                                         -> k' <+> sdoc
           return $ pdoc <+> r
        modekey SuppressAuthor = "-"
        modekey _              = ""
inlineToMarkdown opts lnk@(Link attr txt (src, tit))
  | isEnabled Ext_raw_html opts &&
    not (isEnabled Ext_link_attributes opts) &&
    attr /= nullAttr = -- use raw HTML
    (text . trim) <$> writeHtml5String def (Pandoc nullMeta [Plain [lnk]])
  | otherwise = do
  plain <- asks envPlain
  linktext <- inlineListToMarkdown opts txt
  let linktitle = if null tit
                     then empty
                     else text $ " \"" ++ tit ++ "\""
  let srcSuffix = fromMaybe src (stripPrefix "mailto:" src)
  let useAuto = isURI src &&
                case txt of
                      [Str s] | escapeURI s == srcSuffix -> True
                      _                                  -> False
  let useRefLinks = writerReferenceLinks opts && not useAuto
  shortcutable <- asks envRefShortcutable
  let useShortcutRefLinks = shortcutable &&
                            isEnabled Ext_shortcut_reference_links opts
  ref <- if useRefLinks then getReference attr txt (src, tit) else return []
  reftext <- inlineListToMarkdown opts ref
  return $ if useAuto
              then if plain
                      then text srcSuffix
                      else "<" <> text srcSuffix <> ">"
              else if useRefLinks
                      then let first  = "[" <> linktext <> "]"
                               second = if txt == ref
                                           then if useShortcutRefLinks
                                                   then ""
                                                   else "[]"
                                           else "[" <> reftext <> "]"
                           in  first <> second
                      else if plain
                              then linktext
                              else "[" <> linktext <> "](" <>
                                   text src <> linktitle <> ")" <>
                                   linkAttributes opts attr
inlineToMarkdown opts img@(Image attr alternate (source, tit))
  | isEnabled Ext_raw_html opts &&
    not (isEnabled Ext_link_attributes opts) &&
    attr /= nullAttr = -- use raw HTML
    (text . trim) <$> writeHtml5String def (Pandoc nullMeta [Plain [img]])
  | otherwise = do
  plain <- asks envPlain
  let txt = if null alternate || alternate == [Str source]
                                 -- to prevent autolinks
               then [Str ""]
               else alternate
  linkPart <- inlineToMarkdown opts (Link attr txt (source, tit))
  return $ if plain
              then "[" <> linkPart <> "]"
              else "!" <> linkPart
inlineToMarkdown opts (Note contents) = do
  modify (\st -> st{ stNotes = contents : stNotes st })
  st <- get
  let ref = text $ writerIdentifierPrefix opts ++ show (stNoteNum st + (length $ stNotes st) - 1)
  if isEnabled Ext_footnotes opts
     then return $ "[^" <> ref <> "]"
     else return $ "[" <> ref <> "]"

makeMathPlainer :: [Inline] -> [Inline]
makeMathPlainer = walk go
  where
  go (Emph xs) = Span nullAttr xs
  go x = x

