-module(fuc_ffi).

-export([notify_ready/0, read_file/1]).

notify_ready() ->
    os:cmd("systemd-notify --ready").

read_file(Filepath) ->
    case file:read_file(Filepath, [raw]) of
        {ok, Binary} -> {ok, Binary};
        {error, _} -> {error, nil}
    end.
