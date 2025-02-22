(************************************************************************)
(*         *   The Coq Proof Assistant / The Coq Development Team       *)
(*  v      *         Copyright INRIA, CNRS and contributors             *)
(* <O___,, * (see version control and CREDITS file for authors & dates) *)
(*   \VV/  **************************************************************)
(*    //   *    This file is distributed under the terms of the         *)
(*         *     GNU Lesser General Public License Version 2.1          *)
(*         *     (see LICENSE file for the text of the license)         *)
(************************************************************************)

(* Created by Jean-Christophe Filliâtre out of V6.3 file constants.ml
   as part of the rebuilding of Coq around a purely functional
   abstract type-checker, Nov 1999 *)

(* This module implements kernel-level discharching of local
   declarations over global constants and inductive types *)

open Util
open Names
open Term
open Constr
open Univ
open Context

module NamedDecl = Context.Named.Declaration
module RelDecl = Context.Rel.Declaration

(** {6 Data needed to abstract over the section variables and section universes } *)

(** The generalization to be done on a specific judgment:
    [a:T,b:U,c:V(a) ⊢ w(a,c):W(a,c)
     ~~>
     ⊢ λxz.w(a,c)[a,c:=x,z]:(Πx:T.z:T(a).W(a,c))[a,c:=x,z]]
    so, an abstr_info is both the context x:T,z:V(x) to generalize
    (skipping y which does not occur), and the substitution [a↦x,c↦z]
    where in practice, x and z are canonical (hence implicit) de
    Bruijn indices, that is, only the instantiation [a,c] is kept *)

type abstr_info = {
  abstr_ctx : Constr.rel_context;
  (** Context over which to generalize (e.g. x:T,z:V(x)) *)
  abstr_auctx : Univ.AbstractContext.t;
  (** Universe context over which to generalize *)
  abstr_subst : Id.t list;
  (** Canonical renaming represented by its domain made of the
      actual names of the abstracted term variables (e.g. [a,c]);
      the codomain made of de Bruijn indices is implicit *)
  abstr_ausubst : Univ.universe_level_subst;
  (** Universe substitution *)
}

(** The instantiation to apply to generalized declarations so that
    they behave as if not generalized: this is the a1..an instance to
    apply to a declaration c in the following transformation:
    [a1:T1..an:Tn, C:U(a1..an) ⊢ v(a1..an,C):V(a1..an,C)
     ~~>
     C:Πx1..xn.U(x1..xn), a1:T1..an:Tn ⊢ v(a1..an,Ca1..an):V(a1..an,Ca1..an)]
    note that the data looks close to the one for substitution above
    (because the substitution are represented by their domain) but
    here, local definitions of the context have been dropped *)

type abstr_inst_info = {
  abstr_rev_inst : Id.t list;
  (** The variables to reapply (excluding "let"s of the context), in reverse order *)
  abstr_uinst : Univ.Instance.t;
  (** Abstracted universe variables to reapply *)
}

(** The collection of instantiations to apply to generalized
    declarations so that they behave as if not generalized.
    This accounts for the permutation (lambda-lifting) of global and
    local declarations.
    Using the notations above, a expand_info is a map [c ↦ a1..an]
    over all generalized global declarations of the section *)

type 'a entry_map = 'a Cmap.t * 'a Mindmap.t
type expand_info = abstr_inst_info entry_map

(** The collection of instantiations to be done on generalized
    declarations + the generalization to be done on a specific
    judgment:
    [a1:T1,a2:T2,C:U(a1) ⊢ v(a1,a2,C):V(a1,a2,C)
     ~~>
     c:Πx.U(x) ⊢ λx1x2.(v(a1,a2,cx1)[a1,a2:=x1,x2]):Πx1x2.(V(a1,a2,ca1)[a1,a2:=x1,x2])]
    so, a cooking_info is the map [c ↦ x1..xn],
    the context x:T,y:U to generalize, and the substitution [x,y] *)

type cooking_info = {
  expand_info : expand_info;
  abstr_info : abstr_info;
  abstr_inst_info : abstr_inst_info; (* relevant for recursive types *)
  names_info : Id.Set.t; (* set of generalized names *)
}

let empty_cooking_info = {
  expand_info = (Cmap.empty, Mindmap.empty);
  abstr_info = {
      abstr_ctx = [];
      abstr_subst = [];
      abstr_auctx = AbstractContext.empty;
      abstr_ausubst = Level.Map.empty;
    };
  abstr_inst_info = {
      abstr_rev_inst = [];
      abstr_uinst = Univ.Instance.empty;
    };
  names_info = Id.Set.empty;
}

(*s Cooking the constants. *)

type my_global_reference =
  | ConstRef of Constant.t
  | IndRef of inductive
  | ConstructRef of constructor

module RefHash =
struct
  type t = my_global_reference
  let equal gr1 gr2 = match gr1, gr2 with
  | ConstRef c1, ConstRef c2 -> Constant.SyntacticOrd.equal c1 c2
  | IndRef i1, IndRef i2 -> Ind.SyntacticOrd.equal i1 i2
  | ConstructRef c1, ConstructRef c2 -> Construct.SyntacticOrd.equal c1 c2
  | _ -> false
  open Hashset.Combine
  let hash = function
  | ConstRef c -> combinesmall 1 (Constant.SyntacticOrd.hash c)
  | IndRef i -> combinesmall 2 (Ind.SyntacticOrd.hash i)
  | ConstructRef c -> combinesmall 3 (Construct.SyntacticOrd.hash c)
end

module RefTable = Hashtbl.Make(RefHash)
type internal_abstr_inst_info = Univ.Instance.t * int list * int

type cooking_cache = {
  cache : internal_abstr_inst_info RefTable.t;
  info : cooking_info;
}

let create_cache info = {
  cache = RefTable.create 13;
  info;
}

let instantiate_my_gr gr u =
  match gr with
  | ConstRef c -> mkConstU (c, u)
  | IndRef i -> mkIndU (i, u)
  | ConstructRef c -> mkConstructU (c, u)

let discharge_inst top_abst_subst sub_abst_rev_inst =
  let rec aux k relargs top_abst_subst sub_abst_rev_inst =
    match top_abst_subst, sub_abst_rev_inst with
    | id :: top_abst_subst, id' :: sub_abst_rev_inst' ->
      if Id.equal id id' then
        aux (k+1) (k :: relargs) top_abst_subst sub_abst_rev_inst'
      else
        aux (k+1) relargs top_abst_subst sub_abst_rev_inst
    | _, [] -> relargs
    | [], _ -> assert false in
  aux 1 [] top_abst_subst sub_abst_rev_inst

let rec find_var k id = function
| [] -> raise Not_found
| idc :: subst ->
  if Id.equal id idc then k+1
  else find_var (k+1) id subst

let share cache top_abst_subst r (cstl,knl) =
  try RefTable.find cache r
  with Not_found ->
  let {abstr_uinst;abstr_rev_inst} =
    match r with
    | IndRef (kn,_i) -> Mindmap.find kn knl
    | ConstructRef ((kn,_i),_j) -> Mindmap.find kn knl
    | ConstRef cst -> Cmap.find cst cstl
  in
  let inst = (abstr_uinst, discharge_inst top_abst_subst abstr_rev_inst, List.length abstr_rev_inst) in
  RefTable.add cache r inst;
  inst

let make_inst k abstr_inst_rel =
  Array.map_of_list (fun n -> mkRel (k+n)) abstr_inst_rel

let share_univs cache top_abst_subst k r u l =
  let (abstr_uinst,abstr_inst_rel,_) = share cache top_abst_subst r l in
  mkApp (instantiate_my_gr r (Instance.append abstr_uinst u), make_inst k abstr_inst_rel)

let discharge_proj_repr r p = (* To merge with discharge_proj *)
  let nnewpars = List.length r.abstr_inst_info.abstr_rev_inst in
  let map npars = npars + nnewpars in
  Projection.Repr.map_npars map p

let discharge_proj (_,_,abstr_inst_length) p =
  let map npars = npars + abstr_inst_length in
  Projection.map_npars map p

let is_empty_modlist (cm, mm) =
  Cmap.is_empty cm && Mindmap.is_empty mm

let expand_constr cache modlist top_abst_subst c =
  let share_univs = share_univs cache top_abst_subst in
  let rec substrec k c =
    match kind c with
      | Case (ci, u, pms, p, iv, t, br) ->
        begin match share cache top_abst_subst (IndRef ci.ci_ind) modlist with
        | (abstr_uinst, abstr_inst_rel, abstr_inst_length) ->
          let u = Instance.append abstr_uinst u in
          let pms = Array.append (make_inst k abstr_inst_rel) pms in
          let ci = { ci with ci_npar = ci.ci_npar + abstr_inst_length } in
          Constr.map_with_binders succ substrec k (mkCase (ci,u,pms,p,iv,t,br))
        | exception Not_found ->
          Constr.map_with_binders succ substrec k c
        end

      | Ind (ind,u) ->
          (try
            share_univs k (IndRef ind) u modlist
           with
            | Not_found -> Constr.map_with_binders succ substrec k c)

      | Construct (cstr,u) ->
          (try
             share_univs k (ConstructRef cstr) u modlist
           with
            | Not_found -> Constr.map_with_binders succ substrec k c)

      | Const (cst,u) ->
          (try
            share_univs k (ConstRef cst) u modlist
           with
            | Not_found -> Constr.map_with_binders succ substrec k c)

      | Proj (p, c') ->
          let ind = Names.Projection.inductive p in
          let p' =
            try
              let exp = share cache top_abst_subst (IndRef ind) modlist in
              discharge_proj exp p
            with Not_found -> p in
          let c'' = substrec k c' in
          if p == p' && c' == c'' then c else mkProj (p', c'')

      | Var id ->
          (try
            mkRel (find_var k id top_abst_subst)
           with Not_found -> c)

  | _ -> Constr.map_with_binders succ substrec k c

  in
  if is_empty_modlist modlist && List.is_empty top_abst_subst then c
  else substrec 0 c

(** Cooking is made of 4 steps:
    1. expansion of global constants by applying them to the section
       subcontext they depend on
    2. substitution of named universe variables by de Bruijn universe variables
    3. substitution of named term variables by de Bruijn term variables
    3. generalization of terms over the section subcontext they depend on
       (note that the generalization over universe variable is implicit) *)

(** The main expanding/substitution functions, performing the three first steps *)
let expand_subst cache expand_info abstr_info c =
  let c = expand_constr cache expand_info abstr_info.abstr_subst c in
  let c = Vars.subst_univs_level_constr abstr_info.abstr_ausubst c in
  c

(** Adding the final abstraction step, term case *)
let abstract_as_type { cache; info = { expand_info; abstr_info; _ } } t =
  it_mkProd_wo_LetIn (expand_subst cache expand_info abstr_info t) abstr_info.abstr_ctx

(** Adding the final abstraction step, type case *)
let abstract_as_body { cache; info = { expand_info; abstr_info; _ } } c =
  it_mkLambda_or_LetIn (expand_subst cache expand_info abstr_info c) abstr_info.abstr_ctx

(** Adding the final abstraction step, sort case (for universes) *)
let abstract_as_sort { cache; info = { expand_info; abstr_info; _ } } s =
  destSort (expand_subst cache expand_info abstr_info (mkSort s))

(** Absorb a named context in the transformation which turns a
    judgment [G, Δ ⊢ ΠΩ.J] into [⊢ ΠG.ΠΔ.((ΠΩ.J)[σ][τ])], that is,
    produces the context [Δ(Ω[σ][τ])] and substitutions [σ'] and [τ]
    that turns a judgment [G, Δ, Ω[σ][τ] ⊢ J] into [⊢ ΠG.ΠΔ.((ΠΩ.J)[σ][τ])]
    via [⊢ ΠG.ΠΔ.Π(Ω[σ][τ]).(J[σ'][τ])] *)
let abstract_named_context expand_info abstr_info hyps =
  let fold decl abstr_info =
    let cache = RefTable.create 13 in
    let id, decl = match decl with
    | NamedDecl.LocalDef (id, b, t) ->
      let b = expand_subst cache expand_info abstr_info b in
      let t = expand_subst cache expand_info abstr_info t in
      id, RelDecl.LocalDef (map_annot Name.mk_name id, b, t)
    | NamedDecl.LocalAssum (id, t) ->
      let t = expand_subst cache expand_info abstr_info t in
      id, RelDecl.LocalAssum (map_annot Name.mk_name id, t)
    in
    { abstr_info with
        abstr_ctx = decl :: abstr_info.abstr_ctx;
        abstr_subst = id.binder_name :: abstr_info.abstr_subst }
  in
  Context.Named.fold_outside fold hyps ~init:abstr_info

(** Turn a named context [Δ] (hyps) and a universe named context
    [G] (uctx) into a rel context and abstract universe context
    respectively; computing also the substitution [σ] and universe
    substitution [τ] such that if [G, Δ ⊢ J] is valid then
    [⊢ ΠG.ΠΔ.(J[σ][τ])] is too, that is, it produces the substitutions
    which turns named binders into de Bruijn binders; computing also
    the instance to apply to take the generalization into account;
    collecting the information needed to do such as a transformation
    of judgment into a [cooking_info] *)
let make_cooking_info expand_info hyps uctx =
  let abstr_rev_inst = List.rev (Named.instance_list (fun id -> id) hyps) in
  let abstr_uinst, abstr_auctx = abstract_universes uctx in
  let abstr_ausubst = Univ.make_instance_subst abstr_uinst in
  let abstr_info = { abstr_ctx = []; abstr_subst = []; abstr_auctx; abstr_ausubst } in
  let abstr_info = abstract_named_context expand_info abstr_info hyps in
  let abstr_inst_info = { abstr_rev_inst; abstr_uinst } in
  let names_info = Context.Named.to_vars hyps in
  { expand_info; abstr_info; abstr_inst_info; names_info }

let add_inductive_info ind info =
  let (cmap, imap) = info.expand_info in
  { info with expand_info = (cmap, Mindmap.add ind info.abstr_inst_info imap) }

let names_info info = info.names_info

let abstr_inst_info info = info.abstr_inst_info

let rel_context_of_cooking_cache { info; _ } =
  info.abstr_info.abstr_ctx

let universe_context_of_cooking_info info =
  info.abstr_info.abstr_auctx

let instance_of_cooking_info info =
  Array.map_of_list mkVar (List.rev info.abstr_inst_info.abstr_rev_inst)

let instance_of_cooking_cache { info; _ } =
  instance_of_cooking_info info

let discharge_abstract_universe_context abstr auctx =
  (** Given a substitution [abstr.abstr_ausubst := u₀ ... uₙ₋₁] together with an abstract
      context [abstr.abstr_ctx := 0 ... n - 1 |= C{0, ..., n - 1}] of the same length,
      and another abstract context relative to the former context
      [auctx := 0 ... m - 1 |= C'{u₀, ..., uₙ₋₁, 0, ..., m - 1}],
      construct the lifted abstract universe context
      [0 ... n - 1 n ... n + m - 1 |=
        C{0, ... n - 1} ∪
        C'{0, ..., n - 1, n, ..., n + m - 1} ]
      together with the substitution
      [u₀ ↦ Var(0), ... ,uₙ₋₁ ↦ Var(n - 1), Var(0) ↦  Var(n), ..., Var(m - 1) ↦  Var (n + m - 1)].
  *)
  let open Univ in
  let n = AbstractContext.size abstr.abstr_auctx in
  if (Int.equal n 0) then
    (** Optimization: still need to take the union for the constraints between globals *)
    abstr, AbstractContext.union abstr.abstr_auctx auctx
  else
    let subst = abstr.abstr_ausubst in
    let ainst = make_abstract_instance auctx in
    let substf = Univ.lift_level_subst n (make_instance_subst ainst) in
    let substf = Univ.merge_level_subst subst substf in
    let auctx = Univ.subst_univs_level_abstract_universe_context substf auctx in
    let auctx' = AbstractContext.union abstr.abstr_auctx auctx in
    { abstr with abstr_ausubst = substf }, auctx'

let lift_mono_univs info ctx =
  assert (AbstractContext.is_empty info.abstr_info.abstr_auctx); (* No monorphic constants in a polymorphic section *)
  info, ctx

let lift_poly_univs info auctx =
  (** The constant under consideration is quantified over a
      universe context [auctx]; it has to be quantified further over
      [abstr.abstr_auctx] leading to a new abstraction recipe valid
      under the quantification; that is if we had a judgment
      [G, Δ ⊢ ΠG'.J] to be turned, thanks to [abstr] =
      [{ctx:=Δ;uctx:=G;subst:=σ;usubst:=τ}], into
      [⊢ ΠG.ΠΔ.(ΠG'.J)[σ][τ])], we build the new
      [{ctx:=Δ;uctx:=G(G'[ττ']);subst:=σ;usubst:=ττ'}], for some [τ']
      built by [discharge_abstract_universe_context], that works on
      [J], that is, that allows to turn [GG'[ττ'], Δ ⊢ J] into
      [⊢ ΠG.ΠΔ.(ΠG'.J)[σ][τ]] via [⊢ ΠG(G'[ττ']).ΠΔ.(J[σ][ττ'])] *)
  let abstr_info, auctx = discharge_abstract_universe_context info.abstr_info auctx in
  { info with abstr_info }, auctx

let lift_private_mono_univs info a =
  let () = assert (AbstractContext.is_empty info.abstr_info.abstr_auctx) in
  let () = assert (is_empty_level_subst info.abstr_info.abstr_ausubst) in
  a

let lift_private_poly_univs info (inst, cstrs) =
  let cstrs = Univ.subst_univs_level_constraints info.abstr_info.abstr_ausubst cstrs in
  (inst, cstrs)
