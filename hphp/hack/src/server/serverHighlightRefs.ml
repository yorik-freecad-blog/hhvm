(**
 * Copyright (c) 2016, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the "hack" directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 *
 *)

open Core
open ServerEnv

type result = Pos.absolute list

let get_target symbol =
  let open SymbolOccurrence in
  let open FindRefsService in
  match symbol.type_ with
  | SymbolOccurrence.Class -> Some (IClass symbol.name)
  | SymbolOccurrence.Function -> Some (IFunction symbol.name)
  | SymbolOccurrence.Method (class_name, member_name) ->
      Some (IMember (Subclasses_of class_name,
        FindRefsService.Method member_name))
  | SymbolOccurrence.Property (class_name, member_name) ->
      Some (IMember (Subclasses_of class_name,
        FindRefsService.Property member_name))
  | SymbolOccurrence.ClassConst (class_name, member_name) ->
      Some (IMember (Subclasses_of class_name,
        FindRefsService.Class_const member_name))
  | SymbolOccurrence.Typeconst  (class_name, member_name) ->
      Some (IMember (Subclasses_of class_name,
        FindRefsService.Typeconst member_name))
  | SymbolOccurrence.GConst -> Some (IGConst symbol.name)
  | _ -> None

let highlight_symbol tcopt (line, char) path file_info symbol =
  let res = match get_target symbol with
    | Some target ->
      let results = FindRefsService.find_refs
        (Some tcopt) target [] [(path, file_info)] in
      List.rev (List.map results snd)
    | None when symbol.SymbolOccurrence.type_ = SymbolOccurrence.LocalVar ->
      begin match Parser_heap.ParserHeap.get path with
      | Some ast -> ServerFindLocals.go_from_ast ast line char
      | None -> []
      end
    | None -> []
  in
  List.map res Pos.to_absolute

let filter_result symbols result =
  let result = List.fold symbols ~init:result ~f:(fun result symbol ->
    if (Pos.length symbol.SymbolOccurrence.pos >
      Pos.length result.SymbolOccurrence.pos)
    then result
    else symbol) in
  List.filter symbols ~f:(fun symbol ->
    symbol.SymbolOccurrence.pos = result.SymbolOccurrence.pos)

let compare p1 p2 =
  let line1, start1, _ = Pos.info_pos p1 in
  let line2, start2, _ = Pos.info_pos p2 in
  if line1 < line2 then -1
  else if line1 > line2 then 1
  else if start1 < start2 then -1
  else if start1 > start2 then 1
  else 0

let rec combine_result l l1 l2 =
  match l1, l2 with
  | l1, [] ->
    l @ l1
  | [], l2 ->
    l @ l2
  | h1 :: l1_, h2 :: l2_ ->
    begin
      match compare h1 h2 with
      | -1 -> combine_result (l @ [h1]) l1_ l2
      | 1 -> combine_result (l @ [h2]) l1 l2_
      | 0 -> combine_result (l @ [h1]) l1_ l2_
      | _ -> l
    end

let go_from_file (p, line, column) env =
  let (path, file_info, ast, symbols) = SMap.find_unsafe p env.symbols_cache in
  let symbols = List.filter symbols (fun symbol ->
    IdentifySymbolService.is_target line column symbol.SymbolOccurrence.pos) in
  match symbols with
  | symbol::_ ->
    ServerIdeUtils.oldify_file_info path file_info;
    Parser_heap.ParserHeap.add path ast;
    let {FileInfo.funs; classes; typedefs;_} = file_info in
    NamingGlobal.make_env ~funs ~classes ~typedefs ~consts:[];
    let symbols = filter_result symbols symbol in
    let res = List.fold symbols ~init:[] ~f:(fun acc symbol ->
      combine_result [] acc
        (highlight_symbol env.tcopt (line, column) path file_info symbol)) in
    ServerIdeUtils.revive_file_info path file_info;
    res
  | _ -> []

let go (content, line, char) tcopt =
  ServerIdentifyFunction.get_occurrence_and_map content line char
    ~f:begin fun path file_info symbols ->
      match symbols with
      | symbol::_ ->
        let symbols = filter_result symbols symbol in
        List.fold symbols ~init:[] ~f:(fun acc symbol ->
          combine_result [] acc
            (highlight_symbol tcopt (line, char) path file_info symbol))
      | _ -> []
    end
