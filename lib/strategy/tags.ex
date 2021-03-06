defmodule ClusterEC2.Strategy.Tags do
  @moduledoc """
  This clustering strategy works by loading all instances that have the given
  tag associated with them.

  All instances must be started with the same app name and have security groups
  configured to allow inter-node communication.

      config :libcluster,
        topologies: [
          tags_example: [
            strategy: #{__MODULE__},
            config: [
              ec2_tagname: "mytag",
              ec2_tagvalue: "tagvalue"
              app_prefix: "app"
              ip_type: :private
              polling_interval: 10_000]]]

## Configuration Options

| Key | Required | Description |
| --- | -------- | ----------- |
| `:ec2_tagname` | yes | Name of the EC2 instance tag to look for. |
| `:ec2_tagvalue` | no | Can be passed a static value (string), a 0-arity function, or a 1-arity function (which will be passed the value of `:ec2_tagname` at invocation). |
| `:app_prefix` | no | Will be appended to the node's private IP address to create the node name. |
| `:ip_type` | no | One of :private or :public, defaults to :private |
| `:polling_interval` | no | Number of milliseconds to wait between polls to the EC2 api. Defaults to 5_000 |

  """
  use GenServer
  use Cluster.Strategy
  import Cluster.Logger
  import SweetXml, only: [sigil_x: 2]
  require Logger

  alias Cluster.Strategy.State

  @default_polling_interval 5_000

  def start_link(opts) do
    Application.ensure_all_started(:hackney)
    Application.ensure_all_started(:ex_aws)
    GenServer.start_link(__MODULE__, opts)
  end

  def init(opts) do
    state = %State{
      topology: Keyword.fetch!(opts, :topology),
      connect: Keyword.fetch!(opts, :connect),
      disconnect: Keyword.fetch!(opts, :disconnect),
      list_nodes: Keyword.fetch!(opts, :list_nodes),
      config: Keyword.fetch!(opts, :config),
      meta: MapSet.new([])
    }
    Process.send_after(self(), :load, Keyword.get(state.config, :polling_interval, @default_polling_interval))
    {:ok, state, 0}
  end

  def handle_info(:timeout, state) do
    Logger.info "Process timeout message"
    handle_info(:load, state)
  end

  def handle_info(:load, %State{topology: topology, connect: connect, disconnect: disconnect, list_nodes: list_nodes} = state) do
    Logger.info "Process load message"
    Logger.info "Current nodes: #{inspect state.meta}"
    new_nodelist = MapSet.new(get_nodes(state))
    Logger.info "EC2 nodes: #{inspect new_nodelist}"
    added        = MapSet.difference(new_nodelist, state.meta)
    Logger.info "Added nodes: #{inspect added}"
    removed      = MapSet.difference(state.meta, new_nodelist)
    Logger.info "Removed nodes: #{inspect removed}"
    new_nodelist = case Cluster.Strategy.disconnect_nodes(topology, disconnect, list_nodes, MapSet.to_list(removed)) do
                :ok ->
                  new_nodelist
                {:error, bad_nodes} ->
                  # Add back the nodes which should have been removed, but which couldn't be for some reason
                  Enum.reduce(bad_nodes, new_nodelist, fn {n, _}, acc ->
                    MapSet.put(acc, n)
                  end)
              end
    new_nodelist = case Cluster.Strategy.connect_nodes(topology, connect, list_nodes, MapSet.to_list(added)) do
              :ok ->
                new_nodelist
              {:error, bad_nodes} ->
                # Remove the nodes which should have been added, but couldn't be for some reason
                Enum.reduce(bad_nodes, new_nodelist, fn {n, _}, acc ->
                  MapSet.delete(acc, n)
                end)
            end
    Process.send_after(self(), :load, Keyword.get(state.config, :polling_interval, @default_polling_interval))
    Logger.info "New nodes: #{inspect new_nodelist}"
    {:noreply, %{state | :meta => new_nodelist}}
  end

  def handle_info(message, state) do
    Logger.info "Process #{message} message"
    {:noreply, state}
  end

  @spec get_nodes(State.t) :: [atom()]
  defp get_nodes(%State{topology: topology, config: config}) do
    tag_name = Keyword.fetch!(config, :ec2_tagname)
    tag_value = Keyword.get(config, :ec2_tagvalue, &ClusterEC2.local_instance_tag_value/1)
    app_prefix = Keyword.get(config, :app_prefix, "app")
    cond do
      tag_name != nil and tag_value != nil and app_prefix != nil ->
        params = [filters: ["tag:#{tag_name}": fetch_tag_value(tag_name,tag_value)]]
        request = ExAws.EC2.describe_instances(params)
        Logger.debug "#{inspect request}"
        case ExAws.request(request, region: ClusterEC2.instance_region()) do
          {:ok, %{body: body}} ->
            body
            |> SweetXml.xpath(ip_xpath(Keyword.get(config, :ip_type, :private)))
            |> ip_to_nodename(app_prefix)
          {:error, reason} ->
            error topology, "Error to fetch ec2 nodes: #{inspect reason}"
            []
          _ ->
            []
        end
      tag_name == nil ->
        warn topology, "ec2 tags strategy is selected, but :ec2_tagname is not configured!"
        []
      :else ->
        warn topology, "ec2 tags strategy is selected, but is not configured!"
        []
    end
  end

  defp ip_xpath(:private), do: ~x"//DescribeInstancesResponse/reservationSet/item/instancesSet/item/privateDnsName/text()"ls
  defp ip_xpath(:public), do: ~x"//DescribeInstancesResponse/reservationSet/item/instancesSet/item/publicIpAddress/text()"ls

  defp fetch_tag_value(_k,v) when is_function(v, 0), do: v.()
  defp fetch_tag_value(k,v) when is_function(v, 1), do: v.(k)
  defp fetch_tag_value(_k,v), do: v

  defp ip_to_nodename(list, app_prefix) when is_list(list) do
    list
    |> Enum.map(fn ip ->
      :"#{app_prefix}@#{ip}"
    end)
  end
end
