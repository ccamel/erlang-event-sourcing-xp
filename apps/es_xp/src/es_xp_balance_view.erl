-module(es_xp_balance_view).
-moduledoc """
In-memory read model of bank-account balances.

The view also stores the checkpoint of `bank_account_balance_projection`, so
balances and projection progress share one lifetime: a restarted view replays
the global log from the beginning. Changes at or below the stored position are
ignored, which makes at-least-once delivery idempotent.
""".

-behaviour(gen_server).
-behaviour(es_contract_projection_checkpoint_store).

-export([start_link/0, record_change/3, balance/1, load_checkpoint/1, store_checkpoint/2]).
-export([init/1, handle_call/3, handle_cast/2]).

-define(PROJECTION, bank_account_balance_projection).

-type position() :: es_contract_event_store:position().

-spec start_link() -> gen_server:start_ret().
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-doc "Apply a balance change produced by the event at `Position`.".
-spec record_change(position(), binary(), integer()) -> ok.
record_change(Position, AccountId, Delta) ->
    gen_server:call(?MODULE, {record_change, Position, AccountId, Delta}).

-doc "Return the account balance and the last global position applied to the view.".
-spec balance(binary()) -> {ok, integer(), position() | undefined}.
balance(AccountId) ->
    gen_server:call(?MODULE, {balance, AccountId}).

-spec load_checkpoint(atom()) -> {ok, position()} | {error, not_found}.
load_checkpoint(?PROJECTION) ->
    case gen_server:call(?MODULE, position) of
        undefined -> {error, not_found};
        Position -> {ok, Position}
    end.

-spec store_checkpoint(atom(), position()) -> ok.
store_checkpoint(?PROJECTION, Position) ->
    gen_server:call(?MODULE, {store_checkpoint, Position}).

init([]) ->
    {ok, #{balances => #{}, position => undefined}}.

handle_call({record_change, Position, _AccountId, _Delta}, _From, #{position := Last} = State) when
    is_integer(Last), Position =< Last
->
    {reply, ok, State};
handle_call({record_change, Position, AccountId, Delta}, _From, #{balances := Balances} = State) ->
    Balance = maps:get(AccountId, Balances, 0),
    {reply, ok, State#{balances := Balances#{AccountId => Balance + Delta}, position := Position}};
handle_call({balance, AccountId}, _From, #{balances := Balances, position := Position} = State) ->
    {reply, {ok, maps:get(AccountId, Balances, 0), Position}, State};
handle_call(position, _From, #{position := Position} = State) ->
    {reply, Position, State};
handle_call({store_checkpoint, Position}, _From, State) ->
    {reply, ok, State#{position := Position}}.

handle_cast(_Request, State) ->
    {noreply, State}.
