{-|
Module      : Idris.ElabDecls
Description : Code to elaborate declarations.

License     : BSD3
Maintainer  : The Idris Community.
-}

{-# LANGUAGE DeriveFunctor, FlexibleInstances, MultiParamTypeClasses,
             PatternGuards #-}

module Idris.ElabDecls(elabDecl, elabDecl', elabDecls, elabMain, elabPrims,
                       recinfo) where

import Idris.AbsSyntax
import Idris.Core.Evaluate
import Idris.Core.TT
import Idris.Directives
import Idris.Docstrings hiding (Unchecked)
import Idris.Elab.Clause
import Idris.Elab.Data
import Idris.Elab.Implementation
import Idris.Elab.Interface
import Idris.Elab.Provider
import Idris.Elab.Record
import Idris.Elab.RunElab
import Idris.Elab.Term
import Idris.Elab.Transform
import Idris.Elab.Type
import Idris.Elab.Value
import Idris.Error
import Idris.Options
import Idris.Output (sendHighlighting)
import Idris.Primitives
import Idris.Termination
import IRTS.Lang

import Prelude hiding (id, (.))

import Control.Category
import Control.Monad
import Control.Monad.State.Strict as State
import Data.Maybe
import qualified Data.Text as T

-- | Top level elaborator info, supporting recursive elaboration
recinfo :: FC -> ElabInfo
recinfo fc = EInfo [] emptyContext id [] (Just fc) (fc_fname fc) 0 [] id elabDecl'

-- | Return the elaborated term which calls 'main'
elabMain :: Idris Term
elabMain = do (m, _) <- elabVal (recinfo fc) ERHS
                           (PApp fc (PRef fc [] (sUN "run__IO"))
                                [pexp $ PRef fc [] (sNS (sUN "main") ["Main"])])
              return m
  where fc = fileFC "toplevel"

-- | Elaborate primitives
elabPrims :: Idris ()
elabPrims = do i <- getIState
               let cs_in = idris_constraints i
               let mkdec opt decl docs argdocs =
                       PData docs argdocs defaultSyntax (fileFC "builtin")
                             opt decl
               -- need to temporarily add linearity for this since the
               -- argument may be of restricted type
               addLangExt LinearTypes
               elabDecl' EAll (recinfo primfc) (mkdec inferOpts inferDecl emptyDocstring [])
               dropLangExt LinearTypes
               -- We don't want the constraints generated by 'Infer' since
               -- it's only scaffolding for the elaborator
               i <- getIState
               putIState $ i { idris_constraints = cs_in }
               elabDecl' EAll (recinfo primfc) (mkdec eqOpts eqDecl eqDoc eqParamDoc)

               addNameHint eqTy (sUN "prf")
               mapM_ elabPrim primitives
               -- Special case prim__believe_me because it doesn't work on just constants
               elabBelieveMe
               -- Finally, syntactic equality
               elabSynEq
    where elabPrim :: Prim -> Idris ()
          elabPrim (Prim n ty i def sc tot)
              = do updateContext (addOperator n ty i (valuePrim def))
                   setTotality n tot
                   i <- getIState
                   putIState i { idris_scprims = (n, sc) : idris_scprims i }

          primfc = fileFC "primitive"

          valuePrim :: ([Const] -> Maybe Const) -> [Value] -> Maybe Value
          valuePrim prim vals = fmap VConstant (mapM getConst vals >>= prim)

          getConst (VConstant c) = Just c
          getConst _             = Nothing


          p_believeMe [_,_,x] = Just x
          p_believeMe _ = Nothing
          believeTy = Bind (sUN "a") (Pi RigW Nothing (TType (UVar [] (-2))) (TType (UVar [] (-1))))
                       (Bind (sUN "b") (Pi RigW Nothing (TType (UVar [] (-2))) (TType (UVar [] (-1))))
                         (Bind (sUN "x") (Pi RigW Nothing (V 1) (TType (UVar [] (-1)))) (V 1)))
          elabBelieveMe
             = do let prim__believe_me = sUN "prim__believe_me"
                  updateContext (addOperator prim__believe_me believeTy 3 p_believeMe)
                  -- The point is that it is believed to be total, even
                  -- though it clearly isn't :)
                  setTotality prim__believe_me (Total [])
                  i <- getIState
                  putIState i {
                      idris_scprims = (prim__believe_me, (3, LNoOp)) : idris_scprims i
                    }

          p_synEq [t,_,x,y]
               | x == y = Just (VApp (VApp vnJust VErased)
                                (VApp (VApp vnRefl t) x))
               | otherwise = Just (VApp vnNothing VErased)
          p_synEq args = Nothing

          nMaybe = P (TCon 0 2) (sNS (sUN "Maybe") ["Maybe", "Prelude"]) Erased
          vnJust = VP (DCon 1 2 False) (sNS (sUN "Just") ["Maybe", "Prelude"]) VErased
          vnNothing = VP (DCon 0 1 False) (sNS (sUN "Nothing") ["Maybe", "Prelude"]) VErased
          vnRefl = VP (DCon 0 2 False) eqCon VErased

          synEqTy = Bind (sUN "a") (Pi RigW Nothing (TType (UVar [] (-3))) (TType (UVar [] (-2))))
                     (Bind (sUN "b") (Pi RigW Nothing (TType (UVar [] (-3))) (TType (UVar [] (-2))))
                      (Bind (sUN "x") (Pi RigW Nothing (V 1) (TType (UVar [] (-2))))
                       (Bind (sUN "y") (Pi RigW Nothing (V 1) (TType (UVar [] (-2))))
                         (mkApp nMaybe [mkApp (P (TCon 0 4) eqTy Erased)
                                               [V 3, V 2, V 1, V 0]]))))
          elabSynEq
             = do let synEq = sUN "prim__syntactic_eq"

                  updateContext (addOperator synEq synEqTy 4 p_synEq)
                  setTotality synEq (Total [])
                  i <- getIState
                  putIState i {
                     idris_scprims = (synEq, (4, LNoOp)) : idris_scprims i
                    }


elabDecls :: ElabInfo -> [PDecl] -> Idris ()
elabDecls info ds = do mapM_ (elabDecl EAll info) ds

elabDecl :: ElabWhat -> ElabInfo -> PDecl -> Idris ()
elabDecl what info d
    = let info' = info { rec_elabDecl = elabDecl' } in
          idrisCatch (withErrorReflection $ elabDecl' what info' d) (setAndReport)

elabDecl' _ info (PFix _ _ _)
     = return () -- nothing to elaborate
elabDecl' _ info (PSyntax _ p)
     = return () -- nothing to elaborate
elabDecl' what info (PTy doc argdocs s f o n nfc ty)
  | what /= EDefns
    = do logElab 1 $ "Elaborating type decl " ++ show n ++ show o
         elabType info s doc argdocs f o n nfc ty
         return ()
elabDecl' what info (PPostulate b doc s f nfc o n ty)
  | what /= EDefns
    = do logElab 1 $ "Elaborating postulate " ++ show n ++ show o
         if b
            then elabExtern info s doc f nfc o n ty
            else elabPostulate info s doc f nfc o n ty
elabDecl' what info (PData doc argDocs s f co d)
  | what /= ETypes
    = do logElab 1 $ "Elaborating " ++ show (d_name d)
         elabData info s doc argDocs f co d
  | otherwise
    = do logElab 1 $ "Elaborating [type of] " ++ show (d_name d)
         elabData info s doc argDocs f co (PLaterdecl (d_name d) (d_name_fc d) (d_tcon d))
elabDecl' what info d@(PClauses f o n ps)
  | what /= ETypes
    = do logElab 1 $ "Elaborating clause " ++ show n
         i <- getIState -- get the type options too
         let o' = case lookupCtxt n (idris_flags i) of
                    [fs] -> fs
                    [] -> []
         elabClauses info f (o ++ o') n ps
elabDecl' what info (PMutual f ps)
    = do i <- get
         -- Find the interfaces we're defining in the block so that we can
         -- inline them appropriately before totality checking
         let (ufnames, umethss) = unzip (mapMaybe (findTCImpl i) ps)

         case ps of
              [p] -> elabDecl what info p
              _ -> do mapM_ (elabDecl ETypes info) ps
                      mapM_ (elabDecl EDefns info) ps
         -- record mutually defined data definitions
         let datans = concatMap declared (getDataDecls ps)
         mapM_ (setMutData datans) datans
         logElab 1 $ "Rechecking for positivity " ++ show datans
         mapM_ (\x -> do setTotality x Unchecked) datans
         -- Do totality checking after entire mutual block
         i <- get
         mapM_ (\n -> do logElab 5 $ "Simplifying " ++ show n
                         ctxt' <- do ctxt <- getContext
                                     tclift $ simplifyCasedef n ufnames umethss (getErasureInfo i) ctxt
                         setContext ctxt')
                 (map snd (idris_totcheck i))

         mapM_ buildSCG (idris_totcheck i)
         mapM_ checkDeclTotality (idris_totcheck i)
         -- We've only checked that things are total independently. Given
         -- the ordering, something we think is total might have called
         -- something we hadn't checked yet
         mapM_ verifyTotality (idris_totcheck i)
         clear_totcheck
  where isDataDecl (PData _ _ _ _ _ _) = True
        isDataDecl _ = False

        findTCImpl :: IState -> PDecl -> Maybe (Name, [Name])
        findTCImpl ist (PImplementation _ _ _ _ _ _ _ _ n_in _ ps _ _ expn _)
             = let (n, meths)
                        = case lookupCtxtName n_in (idris_interfaces ist) of
                               [(n', ci)] -> (n', map fst (interface_methods ci))
                               _ -> (n_in, [])
                   iname = mkiname n (namespace info) ps expn in
                   Just (iname, meths)
        findTCImpl ist _ = Nothing

        mkiname n' ns ps' expn' =
           case expn' of
                Nothing -> case ns of
                              [] -> SN (sImplementationN n' (map show ps'))
                              m -> sNS (SN (sImplementationN n' (map show ps'))) m
                Just nm -> nm

        getDataDecls (PNamespace _ _ ds : decls)
           = getDataDecls ds ++ getDataDecls decls
        getDataDecls (d : decls)
           | isDataDecl d = d : getDataDecls decls
           | otherwise = getDataDecls decls
        getDataDecls [] = []

        setMutData ns n
           = do i <- getIState
                case lookupCtxt n (idris_datatypes i) of
                   [x] -> do let x' = x { mutual_types = ns }
                             putIState $ i { idris_datatypes
                                                = addDef n x' (idris_datatypes i) }
                   _ -> return ()

elabDecl' what info (PParams f ns ps)
    = do i <- getIState
         logElab 1 $ "Expanding params block with " ++ show ns ++ " decls " ++
                show (concatMap tldeclared ps)
         let nblock = pblock i
         mapM_ (elabDecl' what info) nblock
  where
    pblock i = map (expandParamsD False i id ns
                      (concatMap tldeclared ps)) ps

elabDecl' what info (POpenInterfaces f ns ds)
    = do open <- addOpenImpl ns
         mapM_ (elabDecl' what info) ds
         setOpenImpl open

elabDecl' what info (PNamespace n nfc ps) =
  do mapM_ (elabDecl' what ninfo) ps
     let ns = reverse (map T.pack newNS)
     sendHighlighting [(nfc, AnnNamespace ns Nothing)]
  where
    newNS = n : namespace info
    ninfo = info { namespace = newNS }

elabDecl' what info (PInterface doc s f cs n nfc ps pdocs fds ds cn cd)
    = do logElab 1 $ "Elaborating interface " ++ show n
         elabInterface info (s { syn_params = [] }) doc what f cs n nfc ps pdocs fds ds cn cd
elabDecl' what info (PImplementation doc argDocs s f cs pnames acc fnopts n nfc ps pextra t expn ds)
    = do logElab 1 $ "Elaborating implementation " ++ show n
         elabImplementation info s doc argDocs what f cs pnames acc fnopts n nfc ps pextra t expn ds
elabDecl' what info (PRecord doc rsyn fc opts name nfc ps pdocs fs cname cdoc csyn)
    = do logElab 1 $ "Elaborating record " ++ show name
         elabRecord info what doc rsyn fc opts name nfc ps pdocs fs cname cdoc csyn
{-
  | otherwise
    = do logElab 1 $ "Elaborating [type of] " ++ show tyn
         elabData info s doc [] f [] (PLaterdecl tyn ty)
-}
elabDecl' _ info (PDSL n dsl)
    = do i <- getIState
         unless (DSLNotation `elem` idris_language_extensions i) $
           ifail "You must turn on the DSLNotation extension to use a dsl block"
         putIState (i { idris_dsls = addDef n dsl (idris_dsls i) })
         addIBC (IBCDSL n)
elabDecl' what info (PDirective i@(DLogging _))
  = directiveAction i
elabDecl' what info (PDirective i)
  | what /= EDefns = directiveAction i
elabDecl' what info (PProvider doc syn fc nfc provWhat n)
  | what /= EDefns
    = do logElab 1 $ "Elaborating type provider " ++ show n
         elabProvider doc info syn fc nfc provWhat n
elabDecl' what info (PTransform fc safety old new)
    = do elabTransform info fc safety old new
         return ()
elabDecl' what info (PRunElabDecl fc script ns)
    = do i <- getIState
         unless (ElabReflection `elem` idris_language_extensions i) $
           ierror $ At fc (Msg "You must turn on the ElabReflection extension to use %runElab")
         elabRunElab info fc script ns
         return ()
elabDecl' _ _ _ = return () -- skipped this time
