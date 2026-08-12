-module(fuc_ffi).

-export([read_file/1]).

read_file(Filepath) ->
    case file:read_file(Filepath, [raw]) of
        {ok, Binary} -> {ok, Binary};
        {error, _} -> {error, nil}
    end.
