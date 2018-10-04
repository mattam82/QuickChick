From QuickChick Require Import QuickChick.
Import GenLow GenHigh.

Require Import List. Import ListNotations.

From QuickChick.ifcbasic Require Import Machine Printing Generation Indist DerivedGen Rules.
From QuickChick.ifcbasic Require GenExec.

Require Import Coq.Strings.String.
Local Open Scope string.

From QuickChick Require Import Mutate MutateCheck.
Require Import ZArith.

Record exp_result := MkExpResult { exp_success : Checker
                                 ; exp_fail    : Checker
                                 ; exp_reject  : Checker
                                 ; exp_check   : bool -> Checker
                                 }.

(* HACK: To get statistics on successful runs/discards/avg test failures, we can 
   assume everything succeeds and collect the result. *)
Definition exp_result_random : exp_result :=
  {| exp_success := collect true  true
   ; exp_fail    := collect false true
   ; exp_reject  := collect "()"  true
   ; exp_check   := (fun b => collect b true)
  |}.

(* For fuzzing, we let afl-fuzz gather the statistics (and hack afl-fuzz instead :) *)
Definition exp_result_fuzz : exp_result :=
  {| exp_success := collect true  true
   ; exp_fail    := collect false false
   ; exp_reject  := collect "()"  tt
   ; exp_check   := (fun b => collect b b)
  |}.

Definition SSNI (t : table) (v : @Variation State) (res : exp_result) : Checker  :=
  let '(V st1 st2) := v in
  let '(St _ _ _ (_@l1)) := st1 in
  let '(St _ _ _ (_@l2)) := st2 in
  match lookupInstr st1 with
  | Some i => 
    if indist st1 st2 then
      match l1, l2 with
        | L,L  =>
          match exec t st1, exec t st2 with
            | Some st1', Some st2' =>
              exp_check res (indist st1' st2')
            | _, _ => exp_reject res
          end
        | H, H =>
          match exec t st1, exec t st2 with
            | Some st1', Some st2' =>
              if is_atom_low (st_pc st1') && is_atom_low (st_pc st2') then
                exp_check res (indist st1' st2')
              else if is_atom_low (st_pc st1') then
                exp_check res (indist st2 st2')
              else
                exp_check res (indist st1 st1')
            | _, _ => exp_reject res
          end
        | H,_ =>
          match exec t st1 with
            | Some st1' =>
              exp_check res (indist st1 st1')
            | _ => exp_reject res
          end
        | _,H =>
          match exec t st2 with
            | Some st2' =>
              exp_check res (indist st2 st2')
            | _ => exp_reject res
          end
      end
    else exp_reject res
  | _ => exp_reject res
  end.


Fixpoint MSNI_aux (fuel : nat) (t : table) (v : @Variation State) : option bool :=
  let '(V st1 st2) := v in
  let '(St _ _ _ (_@l1)) := st1 in
  let '(St _ _ _ (_@l2)) := st2 in
  match fuel with
  | O => Some true
  | S fuel' => 
  match lookupInstr st1 with
  | Some i => 
    if indist st1 st2 then
      match l1, l2 with
      | L,L  =>
        match exec t st1, exec t st2 with
        | Some st1', Some st2' =>
          if indist st1' st2' then
            MSNI_aux fuel' t (V st1' st2')
          else
            Some false
        | _, _ => Some true
          end
        | H, H =>
          match exec t st1, exec t st2 with
            | Some st1', Some st2' =>
              if is_atom_low (st_pc st1') && is_atom_low (st_pc st2') then
                if indist st1' st2' then
                  MSNI_aux fuel' t (V st1' st2')
                else
                  Some false
              else if is_atom_low (st_pc st1') then
                if indist st2 st2' then
                  (* Ensure still a variation by not executing st1 *)
                  MSNI_aux fuel' t (V st1 st2') 
                else Some false
              else
                if indist st1 st1' then
                  MSNI_aux fuel' t (V st1' st2)
                else 
                  Some false
            | _, _ => Some true
          end
        | H,_ =>
          match exec t st1 with
          | Some st1' =>
            if indist st1 st1' then
              MSNI_aux fuel' t (V st1' st2)
            else
              Some false
            | _ => Some true
          end
        | _,H =>
          match exec t st2 with
          | Some st2' =>
            if indist st2 st2' then
              MSNI_aux fuel' t (V st1 st2')
            else Some false
          | _ => Some true
          end
      end
    else None
    | _ => None
  end
  end.

Definition isLow (st : State) :=
  label_eq ∂(st_pc st) L.

(* EENI *)
Fixpoint EENI (fuel : nat) (t : table) (v : @Variation State) res : Checker  :=
  let '(V st1 st2) := v in
  let st1' := execN t fuel st1 in
  let st2' := execN t fuel st2 in
  if indist st1 st2 then 
    match lookupInstr st1', lookupInstr st2' with
    (* run to completion *)
    | Some Halt, Some Halt =>
      if isLow st1' && isLow st2' then
        exp_check res (indist st1' st2') 
      else exp_reject res
    | _, _ => exp_reject res
    end
  else exp_reject res.

(* Generic property *)
Definition prop p (gen : G (option Variation)) (t : table) (r : exp_result) : Checker :=
  forAllShrink gen (fun _ => nil)
               (fun mv =>
                  match mv with
                  | Some v => p t v r
                  | _ => exp_reject r
                  end).

(* Some more gen stuff *)

Definition gen_variation_naive : G (option Variation) :=
  bindGen GenExec.gen_state' (fun st1 =>
  bindGen GenExec.gen_state' (fun st2 =>
  if indist st1 st2 then
    returnGen (Some (V st1 st2))
  else
    returnGen None)).

Definition gen_variation_medium : G (option Variation) :=
  bindGen GenExec.gen_state' (fun st1 =>
  bindGen (Generation.vary st1) (fun st2 =>
  if indist st1 st2 then
    returnGen (Some (V st1 st2))
  else
    returnGen None)).

Extract Constant defNumTests => "100000".

Definition testMutantX prop r n :=
  match nth (mutate_table default_table) n with
    | Some t => prop t r
    | _ => exp_reject r
  end.

Definition prop_SSNI_naive t r :=
  prop SSNI gen_variation_naive t r.

Definition prop_SSNI_medium t r :=
  prop SSNI gen_variation_medium t r.

Definition prop_SSNI_smart t r :=
  prop SSNI (liftGen Some gen_variation_state) t r.

(* QuickChick (prop_SSNI_smart default_table exp_result_random). *)
Definition MSNI fuel t v res :=
  match MSNI_aux fuel t v with
  | Some b => exp_check res b
  | None => exp_reject res
  end.

Definition prop_MSNI_naive t r :=
  prop (MSNI 42) (gen_variation_naive) t r.

Definition prop_MSNI_medium t r :=
  prop (MSNI 42) (gen_variation_medium) t r.

Definition prop_MSNI_smart t r :=
  prop (MSNI 42) (liftGen Some GenExec.gen_variation_state') t r.

(*
QuickChick (prop_MSNI_smart default_table exp_result_random).
QuickCheck (testMutantX prop_MSNI_smart exp_result_random 9).
*)

Definition prop_EENI_naive t r : Checker :=
  prop (EENI 42) (gen_variation_naive) t r.

Definition prop_EENI_medium t r : Checker :=
  prop (EENI 42) (gen_variation_medium) t r.

Definition prop_EENI_smart t r : Checker :=
  prop (EENI 42) (liftGen Some GenExec.gen_variation_state') t r.

(*
QuickChick (prop_EENI_smart default_table exp_result_random).
QuickChick (testMutantX prop_EENI_smart exp_result_random 9).                                 *)        
