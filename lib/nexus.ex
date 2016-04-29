defmodule Nexus do
  defmodule User do
    defmodule StashKey do
      defstruct user_id: "", hub_id: "", stream_id: ""
      
      def to_redis_keys(%StashKey{} = sk),
       do: {"stash{#{sk.user_id}}:#{sk.hub_id}", sk.stream_id}
    end

    defmodule StashRecord do
      defstruct stash_key: %StashKey{}, seq_n: (-1*Redis.hist_length), value: nil


      def to_redis(%StashRecord{seq_n: seq_n, value: value}) when is_integer(seq_n),
       do: "#{seq_n}@#{Poison.encode!(value)}"

      def from_redis!(data, %StashKey{} = key) do
        case String.split(data, "@", parts: 2) do
          [seq_n_bin, value] ->
            %StashRecord{seq_n: String.to_integer(seq_n_bin), value: Poison.decode!(value), stash_key: key}
          _ -> raise ArgumentError
        end
      end
    end

    import Exredis.Api

    defp set_key(user_id), do: "memb{#{user_id}}"
    
    def add_hub(user_id, hub_id) when is_binary(user_id) and is_binary(hub_id),
     do: Nexus.redis |> sadd(set_key(user_id), hub_id); :ok

    def del_hub(user_id, hub_id) when is_binary(user_id) and is_binary(hub_id),
     do: Nexus.redis |> srem(set_key(user_id), hub_id); :ok

    def list_hubs(user_id) when is_binary(user_id),
     do: Nexus.redis |> smembers(set_key(user_id))

    def set_stash(%StashRecord{stash_key: key} = stash) do
      {redis_key, hset_key} = StashKey.to_redis_keys(key)
      if stash.value != nil do
        bin = StashRecord.to_redis(stash)
        Nexus.redis |> hset(redis_key, hset_key, bin)
      else
        Nexus.redis |> hdel(redis_key, hset_key)
      end
      :ok
    end

    def get_stash(%StashKey{} = key) do
      {redis_key, hset_key} = StashKey.to_redis_keys(key)
      case Nexus.redis |> hget(redis_key, hset_key) do
        :undefined -> %StashRecord{stash_key: key}
        bin -> StashRecord.from_redis!(bin, key)
      end
    end
  end

  defmodule Hub do
    import Exredis.Api

    defp set_key(user_id), do: "hubstreams{#{user_id}}"

    def list_default_streams(hub_id) when is_binary(hub_id),
     do: Nexus.redis |> smembers(set_key(hub_id))

    # TODO better to have hub type and then dervie it's entire config from type
    def ensure_hub(hub_id, default_streams, _options \\ [])
    when is_binary(hub_id) and is_list(default_streams) do
      Nexus.redis |> del(set_key(hub_id))
      Nexus.redis |> sadd(set_key(hub_id), default_streams)
      :ok
    end

    #TODO hub should die when the last user leaves it

    defmodule Stream do
      defp room_for_stream(hub_id, stream_id),
       do: "stream:#{hub_id}:#{stream_id}"

      def join(hub_id, stream_id, since \\ 0),
       do: room_for_stream(hub_id, stream_id) |> Broker.subscribe(since)

      def send!(hub_id, stream_id, send_f),
       do: room_for_stream(hub_id, stream_id) |> Broker.send_to!(send_f)
    end

  end

  # TODO
  def redis, do: Process.whereis(:broker_redis_client)

end
