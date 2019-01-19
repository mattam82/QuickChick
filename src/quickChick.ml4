open Ltac_plugin
open Pp
open Names
open Entries
open Declare
open Libnames
open Util
open Constrintern
open Constrexpr
open Error
open Stdarg
open Unix
   
let message = "QuickChick"
let mk_ref s = CAst.make @@ CRef (CAst.make (Qualid (qualid_of_string s)), None)

(* Names corresponding to QuickChick's .v files *)
let show = mk_ref "QuickChick.Show.show"
let quickCheck = mk_ref "QuickChick.Test.quickCheck"
let quickCheckWith = mk_ref "QuickChick.Test.quickCheckWith"
let fuzzCheck = mk_ref "QuickChick.Test.fuzzCheck"
let mutateCheck = mk_ref "QuickChick.MutateCheck.mutateCheck"
let mutateCheckWith = mk_ref "QuickChick.MutateCheck.mutateCheckWith"
let mutateCheckMany = mk_ref "QuickChick.MutateCheck.mutateCheckMany"
let mutateCheckManyWith = mk_ref "QuickChick.MutateCheck.mutateCheckManyWith"
let sample = mk_ref "QuickChick.GenLow.GenLow.sample"

(* let extra_files : (string * string) list ref = ref []  *)
let empty_ss_list : (string * string) list = []           
let extra_files : (string * string) list ref =
  Summary.ref ~name:"QC_extra_files" empty_ss_list
let add_extra_file s1 s2 =
      extra_files := (s1, s2) :: !extra_files
                                             
(* Locate QuickChick's files *)
(* The computation is delayed because QuickChick's libraries are not available
when the plugin is first loaded. *)
(* For trunk and forthcoming Coq 8.5: *)
let qid = Libnames.make_qualid (DirPath.make [Id.of_string "QuickChick"]) (Id.of_string "QuickChick")
			       (*
let qid = qualid_of_string "QuickChick.QuickChick"
				*)
let path =
  lazy (let (_,_,path) = Library.locate_qualified_library ~warn:false qid in path)
let path = lazy (Filename.dirname (Lazy.force path))

(* [mkdir -p]: recursively make the parent directories if they do not exist. *)
let rec mkdir_ dname =
  let cmd () = Unix.mkdir dname 0o755 in
  try cmd () with
  | Unix.Unix_error (Unix.EEXIST, _, _) -> ()
  | Unix.Unix_error (Unix.ENOENT, _, _) ->
    (* If the parent directory doesn't exist, try making it first. *)
    mkdir_ (Filename.dirname dname);
    cmd ()

(* Interface with OCaml compiler *)
let temp_dirname =
  let dname = Filename.(concat (get_temp_dir_name ()) "QuickChick") in
  mkdir_ dname;
  Filename.set_temp_dir_name dname;
  dname

let link_files = ["quickChickLib.cmx"]
(* let link_files = [] *)

(* TODO: in Coq 8.5, fetch OCaml's path from Coq's configure *)
(* FIX: There is probably a more elegant place to put this flag! *)
let ocamlopt = "ocamlopt"
let ocamlc = "ocamlc -unsafe-string"

let eval_command (cmd : string) : string =
  let ic  : in_channel = open_process_in cmd in
  let str : string     = input_line ic       in
  ignore (close_process_in ic);
  str

let comp_ml_cmd tmp_dir fn out =
  let path = Lazy.force path in
  let link_files = List.map (Filename.concat path) link_files in
  let link_files = String.concat " " link_files in
  let afl_path = eval_command "opam config var lib" ^ "/afl-persistent/" in
  let afl_link = afl_path ^ "afl-persistent.cmxa" in
  let extra_link_files =
    String.concat " " (List.map (fun (s : string * string) -> tmp_dir ^ "/" ^ fst s) !extra_files) in
  print_endline ("Extra: " ^ extra_link_files);
  Printf.sprintf "%s -afl-instrument unix.cmxa str.cmxa %s -unsafe-string -rectypes -w a -I %s -I %s -I %s %s %s %s -o %s" ocamlopt afl_link (Filename.dirname fn) afl_path path link_files extra_link_files fn out 
(*  Printf.sprintf "%s unix.cmxa str.cmxa -unsafe-string -rectypes -w a -I %s -I %s %s %s %s -o %s" ocamlopt (Filename.dirname fn) path link_files extra_link_files fn out
 *)
(*
let comp_mli_cmd fn =
  Printf.sprintf "%s -rectypes -I %s %s" ocamlc (Lazy.force path) fn
 *)

let comp_mli_cmd fn =
  let path = Lazy.force path in
  let link_files = List.map (Filename.concat path) link_files in
  let link_files = String.concat " " link_files in
  let afl_link = eval_command "opam config var lib" ^ "/afl-persistent/afl-persistent.cmxa" in 
  Printf.sprintf "%s -afl-instrument unix.cmxa %s -unsafe-string -rectypes -w a -I %s -I %s %s %s" ocamlopt afl_link
    (Filename.dirname fn) path link_files fn

let fresh_name n =
    let base = Id.of_string n in

  (** [is_visible_name id] returns [true] if [id] is already
      used on the Coq side. *)
    let is_visible_name id =
      try
        ignore (Nametab.locate (Libnames.qualid_of_ident id));
        true
      with Not_found -> false
    in
    (** Safe fresh name generation. *)
    Namegen.next_ident_away_from base is_visible_name

(** [define c] introduces a fresh constant name for the term [c]. *)
let define c =
  let env = Global.env () in
  let evd = Evd.from_env env in
  let (evd,_) = Typing.type_of env evd c in
  let uctxt = UState.context (Evd.evar_universe_context evd) in
  let fn = fresh_name "quickchick" in
  (* TODO: Maxime - which of the new internal flags should be used here? The names aren't as clear :) *)
  ignore (declare_constant ~internal:InternalTacticRequest fn
      (DefinitionEntry (definition_entry ~univs:(Polymorphic_const_entry uctxt) (EConstr.to_constr evd c)),
       Decl_kinds.IsDefinition Decl_kinds.Definition));
  fn

(* [$TMP/QuickChick/$TIME/QuickChick.ml],
   where [$TIME] is the current time in format [HHMMSS]. *)
let new_ml_file () =
  let tm = Unix.localtime (Unix.time ()) in
  let ts = Printf.sprintf "%02d%02d%02d" tm.Unix.tm_hour tm.Unix.tm_min tm.Unix.tm_sec in
  let temp_dir = Filename.concat temp_dirname ts in
  mkdir_ temp_dir;
  (temp_dir, Filename.temp_file ~temp_dir "QuickChick" ".ml")

let define_and_run fuzz show_and_c_fun =
  (** Extract the term and its dependencies *)
  let main = define show_and_c_fun in
  let (temp_dir, mlf) = new_ml_file () in
  let execn = Filename.chop_extension mlf in
  let mlif = execn ^ ".mli" in
  let warnings = CWarnings.get_flags () in
  let mute_extraction = warnings ^ (if warnings = "" then "" else ",") ^ "-extraction-opaque-accessed" in
  CWarnings.set_flags mute_extraction;
  Flags.silently (Extraction_plugin.Extract_env.full_extraction (Some mlf)) [CAst.make @@ Ident main];
  CWarnings.set_flags warnings;
  (** Add a main function to get some output *)
  let oc = open_out_gen [Open_append;Open_text] 0o666 mlf in
  if fuzz then begin
  Printf.fprintf oc "
let _ = 
  if Array.length Sys.argv = 1 then
    print_string (QuickChickLib.string_of_coqstring (snd (%s ())))
  else 
    let f () = 
      let quickchick_result =
        try Some ((%s) ())
        with _ -> None
      in
      match quickchick_result with
      | Some (Failure _, s) ->
         print_string (QuickChickLib.string_of_coqstring s); flush stdout;
         failwith \"Test Failed\"
      | Some (_, s) ->
         print_string (QuickChickLib.string_of_coqstring s)
      | _ ->
         print_string \"Failed to generate...\"
    in AflPersistent.run f
" (string_of_id main) (string_of_id main);
  close_out oc;
    end
  else begin
      Printf.fprintf oc "let _ = print_string (QuickChickLib.string_of_coqstring (snd (%s ())))" (string_of_id main);
      close_out oc;
    end;

  List.iter (fun (s : string * string) ->
      let (fn, c) = s in
      let sed_cmd = (Printf.sprintf "sed -i '1s;^;open %s\\n;' %s" c mlf) in
      print_endline ("Sed cmd: " ^ sed_cmd);
      ignore (Sys.command sed_cmd);
      ignore (Sys.command (Printf.sprintf "cp %s %s" fn temp_dir));
    ) !extra_files;

  
  (* Before compiling, remove stupid cyclic dependencies like "type int = int".
     TODO: Generalize (.) \g1\b or something *)
  let perl_cmd = "perl -i -p0e 's/type int =\\s*int/type tmptmptmp = int\\ntype int = tmptmptmp/sg' " ^ mlf in
  if Sys.command perl_cmd <> 0 then
    CErrors.user_err (str ("perl script hack failed. Report: " ^ perl_cmd)  ++ fnl ());
  (** Compile the extracted code *)
  (** Extraction sometimes produces ML code that does not implement its interface.
      We circumvent this problem by erasing the interface. **)
  Sys.remove mlif;
  (* TODO: Maxime, thoughts? *)
  (** LEO: However, sometimes the inferred types are too abstract. So we touch the .mli to close the weak types. **)
  let _exit_code = Sys.command ("touch " ^ mlif) in

  Printf.printf "Extracted ML file: %s\n" mlf;
  Printf.printf "Compile command: %s\n" (comp_ml_cmd temp_dir mlf execn);
  flush_all ();

  (* Compile the (empty) .mli *)
  if Sys.command (comp_mli_cmd mlif) <> 0 then CErrors.user_err (str "Could not compile mli file" ++ fnl ());
  if Sys.command (comp_ml_cmd temp_dir mlf execn) <> 0 then
    (CErrors.user_err (str "Could not compile test program" ++ fnl ()); None)

  (** Run the test *)
  else
    if fuzz then begin
      let input_dir = temp_dir ^ "/input" in
      print_endline input_dir;
      mkdir_ input_dir;
      if Sys.file_exists "./_seeds" then
        Sys.command (Printf.sprintf "cp _seeds/* %s" input_dir)
      else
        Sys.command (Printf.sprintf "echo QuickChick > %s/tmp" input_dir);
      let timeout = 2 * 60 * 60 (* seconds *) in

      begin match Unix.fork() with
      | 0 ->
         (* Kid forks two processes, one that is the worker, one that is the timeout *)
         begin match Unix.fork () with
         | 0 -> (* worker *)
            let cmd = Printf.sprintf "time afl-fuzz -i %s -o %s %s @@" input_dir (temp_dir ^ "/output") execn in
            Printf.printf "Child is executing...\n%s\n" cmd; 
            ignore (Sys.command cmd);
            exit 0;
         | pid_worker ->
            begin match Unix.fork () with
            | 0 -> (* timeout *)
               Printf.printf "Timeout is sleeping for %d seconds...\n" timeout; 
               Unix.sleep timeout;
               exit 0;
            | pid_timeout ->
               (* parent : wait for one process to finish *)
               let (pid', _) = Unix.wait () in
               let kill_cmd = 
                 if pid' = pid_worker then
                   Printf.sprintf "kill -9 %d" pid_timeout
                 else
                   Printf.sprintf "kill -2 $(pgrep afl-fuzz)"
               in
               ignore (Sys.command kill_cmd);
               exit 0;
            end
         end;
      | pid ->
         Printf.printf "Parent is waiting for a child to finish....\n";
         let _ = Unix.wait () in
         let cp_cmd =
           Printf.sprintf "cp %s/output/fuzzer_stats output/%s"
             temp_dir (Filename.basename temp_dir) in
         print_endline cp_cmd;
         ignore (Sys.command cp_cmd);
      end;
      None                               
    end
    else begin 
      (* Should really be shared across this and the tool *)
      (* let chan = Unix.open_process_in execn in *)
      let chan = Unix.open_process_in ("time " ^ execn) in
      let builder = ref [] in
      let rec process_otl_aux () =
        let e = input_line chan in
        print_endline e;
        builder := e :: !builder;
        process_otl_aux() in
      try process_otl_aux ()
      with End_of_file ->
           let stat = Unix.close_process_in chan in
           begin match stat with
           | Unix.WEXITED 0 ->
              ()
           | Unix.WEXITED i ->
              CErrors.user_err (str (Printf.sprintf "Exited with status %d" i) ++ fnl ())
           | Unix.WSIGNALED i ->
              CErrors.user_err (str (Printf.sprintf "Killed (%d)" i) ++ fnl ())
           | Unix.WSTOPPED i ->
              CErrors.user_err (str (Printf.sprintf "Stopped (%d)" i) ++ fnl ())
           end;
           let output = String.concat "\n" (List.rev !builder) in
           Some output
      end

(*
    (** If we want to print the time spent in tests *)
(*    let execn = "time " ^ execn in *)
    if Sys.command execn <> 0 then
      CErrors.user_err (str "Could not run test" ++ fnl ())
 *)

(* TODO: clean leftover files *)
let runTest fuzz (c : constr_expr) =
  (** [c] is a constr_expr representing the test to run,
      so we first build a new constr_expr representing
      show c **)
  let unit_type =
    CAst.make @@ CRef (CAst.make @@ Qualid (qualid_of_string "Coq.Init.Datatypes.unit"), None) in
  let unit_arg =
    CLocalAssum ( [ CAst.make (Name (fresh_name "x")) ], Default Explicit, unit_type ) in
  let pair_ctr =
    CAst.make @@ CRef (CAst.make @@ Qualid (qualid_of_string "Coq.Init.Datatypes.pair"), None) in
  let show_expr cexpr =
    CAst.make @@ CApp((None,show), [(cexpr,None)]) in
  let show_and_c_fun : constr_expr =
    Constrexpr_ops.mkCLambdaN [unit_arg] 
      (let fx = fresh_name "_qc_res" in
       let fx_expr = (CAst.make @@ CRef (CAst.make @@ Libnames.Ident fx,None)) in

       CAst.make @@ CLetIn (CAst.make @@ Name fx, c, None, 
                            CAst.make @@ CApp ((None, pair_ctr),
                                               [(fx_expr, None);
                                                (show_expr fx_expr, None)]))) in
                                                               
  (** Build the kernel term from the const_expr *)
  let env = Global.env () in
  let evd = Evd.from_env env in
  let (show_and_c_fun, evd) = interp_constr env evd show_and_c_fun in

  define_and_run fuzz show_and_c_fun

let qcFuzz prop fuzzLoop =
  (** Extract the property and its dependencies *)
  let env = Global.env () in
  let evd = Evd.from_env env in
  let (prop_expr, evd) = interp_constr env evd prop in
  let prop_def = define prop_expr in
  let (temp_dir, prop_mlf) = new_ml_file () in
  let execn = Filename.chop_extension prop_mlf in
  let prop_mlif = execn ^ ".mli" in
  let warnings = CWarnings.get_flags () in
  let mute_extraction = warnings ^ (if warnings = "" then "" else ",") ^ "-extraction-opaque-accessed" in
  CWarnings.set_flags mute_extraction;
  Flags.silently (Extraction_plugin.Extract_env.full_extraction (Some prop_mlf)) [CAst.make @@ Ident prop_def];
  CWarnings.set_flags warnings;

  (** Override extraction to use the new, instrumented property *)
  let prop_name = Filename.basename execn ^ "." ^ Id.to_string prop_def in
  let prop_ref =
    match prop with
    | { CAst.v = CRef (r,_) } -> r
    | _ -> failwith "Not a reference"
  in
  Extraction_plugin.Table.extract_constant_inline false prop_ref [] prop_name;

  (** Define fuzzLoop applied appropriately *)
  let unit_type =
    CAst.make @@ CRef (CAst.make @@ Qualid (qualid_of_string "Coq.Init.Datatypes.unit"), None) in
  let unit_arg =
    CLocalAssum ( [ CAst.make (Name (fresh_name "x")) ], Default Explicit, unit_type ) in
  let pair_ctr =
    CAst.make @@ CRef (CAst.make @@ Qualid (qualid_of_string "Coq.Init.Datatypes.pair"), None) in
  let show_expr cexpr =
    CAst.make @@ CApp((None,show), [(cexpr,None)]) in
  let show_and_c_fun : constr_expr =
    Constrexpr_ops.mkCLambdaN [unit_arg] 
      (let fx = fresh_name "_qc_res" in
       let fx_expr = (CAst.make @@ CRef (CAst.make @@ Libnames.Ident fx,None)) in

       CAst.make @@ CLetIn (CAst.make @@ Name fx, fuzzLoop, None, 
                            CAst.make @@ CApp ((None, pair_ctr),
                                               [(fx_expr, None);
                                                (show_expr fx_expr, None)]))) in
  
  (** Build the kernel term from the const_expr *)
  let env = Global.env () in
  let evd = Evd.from_env env in
  let (show_and_c_fun, evd) = interp_constr env evd show_and_c_fun in

  let show_and_c_fun_def = define show_and_c_fun in
  let mlf = Filename.temp_file ~temp_dir "QuickChick" ".ml" in
  let execn = Filename.chop_extension mlf in
  let mlif = execn ^ ".mli" in
  let mute_extraction = warnings ^ (if warnings = "" then "" else ",") ^ "-extraction-opaque-accessed" in
  Flags.silently (Extraction_plugin.Extract_env.full_extraction (Some mlf)) [CAst.make @@ Ident show_and_c_fun_def];
  CWarnings.set_flags warnings;

  (** Add a main function to get some output *)
  let oc = open_out_gen [Open_append;Open_text] 0o666 mlf in
  Printf.fprintf oc "
let _ = 
  print_endline \"Calling setup_sum_aux()...\\n\"; flush stdout;
  setup_shm_aux ();
  print_endline \"setup_sum_aux() called succesfully\\n\";
  let f () = 
    let quickchick_result =
      try Some ((%s) ())
      with _ -> None
    in
    match quickchick_result with
    | Some (Failure _, s) ->
       print_string (QuickChickLib.string_of_coqstring s); flush stdout;
       failwith \"Test Failed\"
    | Some (_, s) ->
       print_string (QuickChickLib.string_of_coqstring s)
    | _ ->
       print_string \"Failed to generate...\"
  in f ()
" (string_of_id show_and_c_fun_def);
  close_out oc;

  (* Append the appropriate definitions in the beginning *)
  let user_contrib = "$(opam config var lib)/coq/user-contrib/QuickChick" in
  (* Add preamble *)
  let echo_cmd =
    Printf.sprintf "cat %s/Stub.ml | cat - %s > temp && mv temp %s" user_contrib mlf mlf in
  print_endline echo_cmd;
  ignore (Sys.command echo_cmd);

  (* Copy fuzz-related files to temp directory *)
  ignore (Sys.command (Printf.sprintf "cp %s/alloc-inl.h %s" user_contrib temp_dir));
  ignore (Sys.command (Printf.sprintf "cp %s/debug.h %s" user_contrib temp_dir));
  ignore (Sys.command (Printf.sprintf "cp %s/types.h %s" user_contrib temp_dir));
  ignore (Sys.command (Printf.sprintf "cp %s/config.h %s" user_contrib temp_dir));
  ignore (Sys.command (Printf.sprintf "cp %s/SHM.c %s" user_contrib temp_dir));

  (* Compile. Prop with instrumentation, rest without *)
  let path = Lazy.force path in
  let link_files = List.map (Filename.concat path) link_files in
  let link_files = String.concat " " link_files in
  let afl_path = eval_command "opam config var lib" ^ "/afl-persistent/" in
  let afl_link = afl_path ^ "afl-persistent.cmxa" in
  let extra_link_files =
    String.concat " " (List.map (fun (s : string * string) -> temp_dir ^ "/" ^ fst s) !extra_files) in
  print_endline ("Extra: " ^ extra_link_files);

  let comp_mli_cmd instr_flag fn =
    Printf.sprintf "%s %s unix.cmxa %s -unsafe-string -rectypes -w a -I %s -I %s %s %s" ocamlopt instr_flag afl_link
      (Filename.dirname fn) path link_files fn
  in

  let comp_prop_ml_cmd fn = 
    Printf.sprintf "%s -afl-instrument unix.cmxa str.cmxa %s -unsafe-string -rectypes -w a -I %s -I %s -I %s %s %s %s"
      ocamlopt afl_link (Filename.dirname fn) afl_path path link_files extra_link_files fn
  in 

  let comp_exec_ml_cmd fn prop_fn execn =
    Printf.sprintf "%s unix.cmxa str.cmxa %s -unsafe-string -rectypes -w a -I %s -I %s -I %s %s %s %s -o %s %s %s/SHM.c"
      ocamlopt afl_link (Filename.dirname fn) afl_path path link_files extra_link_files (Filename.chop_extension prop_fn ^ ".cmx") execn fn temp_dir
  in

  (* Compile the .mli *)
  if Sys.command (comp_mli_cmd "-afl-instrument" prop_mlif) <> 0 then CErrors.user_err (str "Could not compile mli file" ++ fnl ());
  (* Compile the instrumented property .ml *)
  if Sys.command (comp_prop_ml_cmd prop_mlf) <> 0 then
    (CErrors.user_err (str "Could not compile test program" ++ fnl ()));

  (* Compile the executable .mli, no instrumentation *)
  if Sys.command (comp_mli_cmd " " mlif) <> 0 then CErrors.user_err (str "Could not compile exec mli file" ++ fnl ());
  (* Compile the actual executable *)
  let cmp_cmd = comp_exec_ml_cmd mlf prop_mlf (temp_dir ^ "/qc_exec") in
  Printf.printf "Compile Command: %s\n" cmp_cmd;
  if Sys.command (cmp_cmd) <> 0 then
    (CErrors.user_err (str "Could not compile exec program" ++ fnl ()));

  (* Copy over the main file that actually sets up the shm... *)
  ignore (Sys.command (Printf.sprintf "cp %s/Main.ml %s" user_contrib temp_dir));
  let comp_main_cmd fn execn : string = 
    Printf.sprintf "%s unix.cmxa str.cmxa %s -unsafe-string -rectypes -w a -I %s -I %s -I %s %s %s -o %s %s %s/SHM.c"
      ocamlopt afl_link (Filename.dirname fn) afl_path path link_files extra_link_files execn fn temp_dir in
  let cmp_cmd_main = comp_main_cmd (temp_dir ^ "/Main.ml") (temp_dir ^ "/main_exec") in
  if (Sys.command cmp_cmd_main <> 0) then
    (CErrors.user_err (str "Could not compile main program" ++ fnl ()));
  
  ignore (Sys.command (temp_dir ^ "/main_exec " ^ temp_dir ^ "/qc_exec"))
  (* open linked ocaml files 
  List.iter (fun (s : string * string) ->
      let (fn, c) = s in
      let sed_cmd = (Printf.sprintf "sed -i '1s;^;open %s\\n;' %s" c mlf) in
      print_endline ("Sed cmd: " ^ sed_cmd);
      ignore (Sys.command sed_cmd);
      ignore (Sys.command (Printf.sprintf "cp %s %s" fn temp_dir));
    ) !extra_files;
   *)
  

  

      
  
let run fuzz f args =
  begin match args with
  | qc_text :: _ -> Printf.printf "QuickChecking %s\n"
                      (Pp.string_of_ppcmds (Ppconstr.pr_constr_expr qc_text));
                      flush_all()
  | _ -> failwith "run called with no arguments"
  end;
  let args = List.map (fun x -> (x,None)) args in
  let c = CAst.make @@ CApp((None,f), args) in
  ignore (runTest fuzz c)

let set_debug_flag (flag_name : string) (mode : string) =
  let toggle =
    match mode with
    | "On"  -> true
    | "Off" -> false
  in
  let reference =
    match flag_name with
    | "Debug" -> flag_debug
(*    | "Warn"  -> flag_warn
    | "Error" -> flag_error *)
  in
  reference := toggle 
(*  Libobject.declare_object
    {(Libobject.default_object ("QC_debug_flag: " ^ flag_name)) with
       cache_function = (fun (_,(flag_name, mode)) -> reference flag_name := toggle mode);
       load_function = (fun _ (_,(flag_name, mode)) -> reference flag_name := toggle mode)}
 *)
	  (*
let run_with f args p =
  let c = CApp(dummy_loc, (None,f), [(args,None);(p,None)]) in
  runTest c
	   *)

VERNAC COMMAND EXTEND QuickCheck CLASSIFIED AS SIDEFF
  | ["QuickCheck" constr(c)] ->     [run false quickCheck [c]]
  | ["QuickCheckWith" constr(c1) constr(c2)] ->     [run false quickCheckWith [c1;c2]]
END;;

VERNAC COMMAND EXTEND QuickChick CLASSIFIED AS SIDEFF
  | ["QuickChick" constr(c)] ->     [run false quickCheck [c]]
  | ["QuickChickWith" constr(c1) constr(c2)] ->     [run false quickCheckWith [c1;c2]]
END;;

VERNAC COMMAND EXTEND FuzzChick CLASSIFIED AS SIDEFF
  | ["FuzzChick" constr(c)] ->     [run true fuzzCheck [c]]
END;;

VERNAC COMMAND EXTEND MutateCheck CLASSIFIED AS SIDEFF
  | ["MutateCheck" constr(c1) constr(c2)] ->     [run false mutateCheck [c1;c2]]
  | ["MutateCheckWith" constr(c1) constr(c2) constr(c3)] ->     [run false mutateCheckWith [c1;c2;c3]]
END;;

VERNAC COMMAND EXTEND MutateChick CLASSIFIED AS SIDEFF
  | ["MutateChick" constr(c1) constr(c2)] ->     [run false mutateCheck [c1;c2]]
  | ["MutateChickWith" constr(c1) constr(c2) constr(c3)] ->     [run false mutateCheckWith [c1;c2;c3]]
END;;

VERNAC COMMAND EXTEND MutateCheckMany CLASSIFIED AS SIDEFF
  | ["MutateCheckMany" constr(c1) constr(c2)] ->     [run false mutateCheckMany [c1;c2]]
  | ["MutateCheckManyWith" constr(c1) constr(c2) constr(c3)] ->     [run false mutateCheckMany [c1;c2;c3]]
END;;

VERNAC COMMAND EXTEND MutateChickMany CLASSIFIED AS SIDEFF
  | ["MutateChickMany" constr(c1) constr(c2)] ->     [run false mutateCheckMany [c1;c2]]
  | ["MutateChickManyWith" constr(c1) constr(c2) constr(c3)] ->     [run false mutateCheckMany [c1;c2;c3]]
END;;

VERNAC COMMAND EXTEND FuzzQC CLASSIFIED AS SIDEFF
  | ["FuzzQC" constr(prop) constr(fuzzLoop) ] ->  [ qcFuzz prop fuzzLoop ]
END;;

VERNAC COMMAND EXTEND QuickChickDebug CLASSIFIED AS SIDEFF
  | ["QuickChickDebug" ident(s1) ident(s2)] ->
     [ let s1' = Id.to_string s1 in
       let s2' = Id.to_string s2 in
       set_debug_flag s1' s2' ]
END;;

VERNAC COMMAND EXTEND AddExtraFile CLASSIFIED AS SIDEFF
  | ["AddExtraFile" string(s1) string(s2)] ->
     [ ( add_extra_file s1 s2;
         print_endline (String.concat " " (List.map fst !extra_files))
       ) ]
END;;

VERNAC COMMAND EXTEND Sample CLASSIFIED AS SIDEFF
  | ["Sample" constr(c)] -> [run false sample [c]]
END;;
