%%
%% $Id: $
%%
%% Module:  jsc -- description
%% Created: 10-JUN-2012 13:34
%% Author:  tmr
%%

%% @doc JavaScript Compiler for Erlang.
-module (jsc).
-export ([compile/1, compile/2, compile_file/1, compile_file/2]).
-compile (export_all).

-define (JS_FILE_EXT, ".js").
-define (JSC_FILE_EXT, ".jsc.js").

-type jsc_code ()
   :: string () | list () | binary (). %% JavaScript Compiler Input Code.
-type jsc_options ()
   :: proplists:proplist (). %% JavaScript Compiler Options.
-type jsc_result ()
   :: {ok, Module::atom ()} | any (). %% JavaScript Compiler Result.

%% @equiv compile_file (File, [])
-spec compile_file (File::string ()) -> jsc_result ().
compile_file (File) -> compile_file (File, []).

%% @doc Call compile on the contents of `File'.
-spec compile_file (File::string (),
                    Options::jsc_options ()) -> jsc_result ().
compile_file (File, Options) ->
  {ok, Bin} = file:read_file (File),
  compile (Bin, Options).

%% @equiv compile (Code, [])
%-spec compile_file (Code::jsc_code ()) -> jsc_result ().
compile (Code) -> compile (Code, []).

%% @doc JavaScript pseudo-compiler.
%%
%% Returns values:
%% <ul>
%% <li>`{ok, Module, Res}' -- success, `Module'
%% is autogenerated unique ID of the JavaScript
%% (hash). If caching is enabled, the `Res' is
%% filename of file with compiled JavaScript.
%% Otherwise `Res' is just a string with compiled
%% JavaScript source code.</li>
%% </ul>
%%
%% Options:
%% <ul>
%% <li>`dry_run' -- run the transformation, but
%% return the original JavaScript input instead
%% of the compiled one</li>
%% <li>`no_result' -- will return empty data
%% buffer and it's up on caller to fetch cached
%% data file directly from `file_cache_dir'.
%% Makes sense only when used with `file_cache'.</li>
%% <li>`file_cache' -- enable file-cache</li>
%% <li>`{file_cache_dir, Path}' -- directory
%% where to store cached files</li>
%% </ul>
-spec compile (Code::jsc_code (),
               Options::jsc_options ()) -> jsc_result ().
compile (Code, Options) when is_binary (Code) ->
  compile (binary_to_list (Code), Options);
compile (Code, Options) when is_list (Code) ->
  Module = cache_module_name (Code),
  Compile = fun () ->
    case proplists:is_defined (dry_run, Options) of
      true -> Code; false -> min_js (Code, []) end end,
  CacheDir = proplists:get_value (file_cache_dir, Options),
  RequestContent = not proplists:is_defined (no_result, Options),

  case proplists:is_defined (file_cache, Options) of
    true ->
      case cache_load (Module, CacheDir, RequestContent) of
        {match, Data} -> {ok, Module, Data};
        match -> {ok, Module};
        nomatch ->
          case cache_store (Module, CacheDir, Compile ()) of
            {ok, Content} -> {ok, Module, Content};
            {error, Err}  -> {error, Module, Err}
          end;
        {error, Reason} -> {error, Module, Reason}
      end;
    false -> {ok, Module, Compile ()}
  end.

cache_store (Module, CacheDir, Content) ->
  cache (store, Module, CacheDir, Content, false).
cache_load (Module, CacheDir, RequestContent) ->
  cache (load, Module, CacheDir, [], RequestContent).
cache (Direction, Module, CacheDir, Content, RequestContent) ->
  Load = fun (File) ->
    case filelib:is_file (File) of
      true ->
        case RequestContent of
          true ->
            case file:read_file (File) of
              {ok, Bin} -> {match, binary_to_list (Bin)};
              _         -> nomatch
            end;
          false -> match
        end;
      false -> nomatch
    end
  end,
  case CacheDir of
    undefined ->
      {error, no_cache_dir};
    Directory ->
      File = filename:join ([Directory, Module ++ ?JSC_FILE_EXT]),
      case Direction of
        store ->
          case file:write_file (File, Content) of
            ok           -> {ok, Content};
            {error, Err} -> {error, Err}
          end;
        load -> Load (File)
      end
  end.

cache_module_name (Code) ->
  lists:map (fun (B) -> $A+B-$0 end,
    integer_to_list (erlang:phash2(Code))).


%% jsmin in Erlang
%% <http://javascript.crockford.com/jsmin.html>
%% NOTE: The production version of JQuery.min.js is actually compressed/altered,
%% (by hand?) and includes http://sizzlejs.com/ - so this function won't generate a 
%% duplicate of the JQuery minified delivery. It will, however, duplicate the result
%% of using: jsmin <jquery-{version}.js >jquery-{version}.min.js

%% Replace // comments with LF
min_js([$/, $/|T], Acc) ->
  Rest = skip_to($\n, T),
  min_js([$\n|Rest], Acc);
%% Replace /* */ comments with a space
min_js([$/, $*|T], Acc) ->
  Rest = skip_to([$*, $/], T),
  min_js([$ |Rest], Acc);
%% Trap regex
min_js([$/|T], [Prev|Acc]) ->
  {Rest, Acc1} = 
    case is_js_regex(Prev) of
    true -> read_to($/, T, [$/, Prev|Acc]);
    false -> {T, [$/, Prev|Acc]}
    end,
  min_js(Rest, Acc1);
%% Trap double quoted strings...
min_js([$"|T], Acc) ->
  {Rest, Acc1} = read_to($", T, [$"|Acc]),
  min_js(Rest, Acc1);
%% Trap single-quoted strings...
min_js([$'|T], Acc) ->
  {Rest, Acc1} = read_to($', T, [$'|Acc]),
  min_js(Rest, Acc1);
%% Replace CR with LF
min_js([$\r|T], Acc) ->
  min_js([$\n|T], Acc);
%% Replace ctrl chars except LF, (but including TAB) with a space
%% NOTE: Assumes "ctrl chars" for ASCII cover all control chars
min_js([H|T], Acc) when H =:= 127 
    orelse (H < 32 andalso H =/= 10) -> 
  min_js([$ |T], Acc);
%% Reduce runs of spaces to one space
min_js([$ |T], Acc = [$ |_]) ->
  min_js(T, Acc);
%% Reduce runs of LF to one LF
min_js([$\n|T], Acc = [$\n|_]) ->
  min_js(T, Acc); 
%% Pre-Collapse whitespace
min_js([$\n, $ |T], Acc) ->
  min_js([$\n|T], Acc);
min_js([$\n, $\t|T], Acc) ->
  min_js([$\n|T], Acc);
min_js([$\n, $\r|T], Acc) ->
  min_js([$\n|T], Acc);
%% For compliance with Cockroft's jsmin.c implementation, trim any leading SPACE
min_js([$ |T], []) ->
  min_js(T, []);
%% For compliance with Cockroft's jsmin.c implementation, trim the trailing LF
min_js([$\n], Acc) ->
  min_js([], Acc);
%% Drop space when permissable
min_js([$ , Next|T], [Prev|Acc]) ->
  case is_omit_unsafe(Prev, $ , Next) of
  true -> min_js([Next|T], [$ , Prev|Acc]);
  false -> min_js([Next|T], [Prev|Acc])
  end;
%% Drop LF when permissable
min_js([$\n, Next|T], [Prev|Acc]) ->
  case is_omit_unsafe(Prev, $\n, Next) of
  true -> min_js([Next|T], [$\n, Prev|Acc]);
  false -> min_js([Next|T], [Prev|Acc])
  end;
%% Don't touch anything else
min_js([H|T], Acc) ->
  min_js(T, [H|Acc]);
min_js([], Acc) ->
  lists:reverse(Acc).

% found terminal char, return
skip_to(X, [X|T]) -> 
  T;
% found terminal chars, return
skip_to([X, Y], [X, Y|T]) -> 
  T;
% pass over everything else
skip_to(Match, [_H|T]) -> 
  skip_to(Match, T);
% error
skip_to(_, []) -> 
  throw("Unterminated Comment").

%% trap escapes
read_to(X, [$\\, H|T], Acc) -> 
  read_to(X, T, [H, $\\|Acc]);
% found terminal char, return
read_to(X, [X|T], Acc) -> 
  {T, [X|Acc]};
% pass through everything else
read_to(X, [H|T], Acc) -> 
  read_to(X, T, [H|Acc]);
% error
read_to(_, [], _Acc) -> 
  throw("Unterminated String").

%% Found / when previous non-ws char is one of:
%% ( ,  =  :  [  !  &  |  ?  {  }  ;  \n
is_js_regex(Prev) ->
  case re:run(<<Prev>>, "[\(,=:\[!&\|\?{};\n]") of
  {match, _} -> true;
  nomatch -> false
  end.

%% jsmin Spec: Omit space except when it is preceded and followed by a non-ASCII character 
%% or by an ASCII letter or digit, or by one of these characters: \ $ _
is_omit_unsafe(Prev, $ , Next) ->
  Regex = "[A-Za-z0-9_\\\\$]",
  is_match(Next, Regex) 
  andalso is_match(Prev, Regex);
%% jsmin Spec: Omit linefeed except:
%% if it follows a non-ASCII character or an ASCII letter or digit 
%% or one of these characters:  \ $ _ } ] ) + - " '
%% AND if it precedes a non-ASCII character or an ASCII letter or digit 
%% or one of these characters:  \ $ _ { [ ( + -
is_omit_unsafe(Prev, $\n, Next) ->
  (Prev =:= $" orelse Prev =:= $' 
    orelse is_match(Prev, "[A-Za-z0-9\\\\$_}\\]\)\+-]")) 
  andalso is_match(Next, "[A-Za-z0-9\\\\\$_{\[\(\+-]").
%%
is_match(X, Regex) ->
  case re:run(<<X>>, Regex) of
  {match, _} -> true;
  nomatch when X >= 128 -> true; % include non-ascii chars
  nomatch -> false
  end.

%% vim: fdm=syntax:fdn=3:tw=74:ts=2:syn=erlang
