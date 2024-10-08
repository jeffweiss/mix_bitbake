defmodule Mix.Tasks.Bitbake do
  @moduledoc """
  Generates BitBake recipes utilizing the classes from meta-erlang.
  """
  @shortdoc "Generates BitBake recipes utilizing the classes from meta-erlang."

  use Mix.Task

  @mix_bitbake_ver "0.1.0"
  @default_license_files ["LICENSE", "LICENSE.md", "COPYING", "COPYING.md"]

  @impl Mix.Task
  @spec run(OptionParser.argv()) :: no_return
  def run(_args) do
    Mix.Project.get!()
    project = Mix.Project.config()
    target = make_recipe_filename(File.cwd!(), project)
    assigns = make_assigns(File.cwd!(), project)
    template(target, assigns)

    Mix.shell().info([:green, "* Wrote ", :reset, target])

    target = make_recipe_includes_filename(File.cwd!(), project)
    assigns = make_assigns(File.cwd!(), project)
    template(target, assigns, "bitbake-inc.eex")

    Mix.shell().info([:green, "* Wrote ", :reset, target])
  end

  defp make_recipe_filename(dir, project) do
    version = Keyword.fetch!(project, :version)
    app = name(project)
    Path.join([dir, "#{app}_#{version}.bb"])
  end

  defp make_recipe_includes_filename(dir, project) do
    version = Keyword.fetch!(project, :version)
    app = name(project)
    Path.join([dir, "#{app}-#{version}.inc"])
  end

  defp make_assigns(dir, project) do
    [
      {:mix_bitbake_ver, @mix_bitbake_ver},
      {:name, name(project)},
      {:summary, description(project)},
      {:license, license(project)},
      {:homepage, homepage(project)},
      {:project_src_uri, src_uri(dir)},
      {:project_src_rev, git_ref(dir)},
      {:lic_files, license_files(dir)},
      {:deps, deps()}
    ]
  end

  defp name(project) do
    project
    |> Keyword.fetch!(:app)
    |> dashify
  end

  defp dashify(token) do
    token
    |> to_string
    |> String.replace("_", "-")
  end

  defp description(project) do
    Keyword.get(project, :description, "")
  end

  # relies on ex_doc mix project fields, if exists
  defp homepage(project) do
    Keyword.get(project, :homepage_url, "")
  end

  defp deps() do
    Mix.Dep.cached()
    |> Enum.filter(fn
      %Mix.Dep{scm: Mix.SCM.Git, opts: opts} ->
        git_uri = Keyword.fetch!(opts, :git)
        String.starts_with?(git_uri, "git@")

      _ ->
        false
    end)
    |> Enum.sort_by(fn dep -> dep.app end)
    |> Enum.map(fn
      %Mix.Dep{app: name, opts: opts} ->
        uri = Keyword.fetch!(opts, :git)
        lock = Keyword.fetch!(opts, :lock)
        sha = elem(lock, 2)
        regex_caps = Regex.named_captures(~r/(?<username>[^@]+)@(?<host>[^:]+):(?<path>.+)/, uri)

        %{
          name: name,
          # rebuilding because most of the git uris have user@host:path
          # and we need user@host/path
          uri:
            "git://#{regex_caps["username"]}@#{regex_caps["host"]}/#{regex_caps["path"]};protocol=ssh;nobranch=1;name=#{name};destsuffix=#{name}",
          sha: sha
        }
    end)
  end

  # relies on hex publish package, if exists
  defp license(project) do
    case project[:package][:licenses] do
      [license | _] ->
        license

      [] ->
        Mix.raise("The :license can not be an empty string")

      nil ->
        Mix.raise(
          "Could not find license for #{inspect(project[:app])}, please make sure that one license has added"
        )
    end
  end

  defp license_files(dir) do
    @default_license_files
    |> Enum.filter(fn license ->
      dir |> Path.join(license) |> File.regular?()
    end)
    |> Enum.map(fn license ->
      md5digest = dir |> Path.join(license) |> get_md5()
      "file://#{license};md5=#{md5digest} \\ \n"
    end)
  end

  defp src_uri(_dir) do
    uri =
      ["config", "--get", "remote.origin.url"]
      |> git!()

    branch =
      ["rev-parse", "--abbrev-ref", "HEAD"]
      |> git!()

    parse_uri(uri, branch)
  end

  def parse_uri(uri, branch) do
    branch = String.trim(branch)
    uri = uri |> String.trim("\n")

    scp =
      [
        Regex.named_captures(
          ~r/(?<proto>[^@]+):\/\/(?<username>[^@]+)@(?<host>[^:\/]+)\/(?<path>.+)/,
          uri
        ),
        Regex.named_captures(~r/(?<proto>[^@]+):\/\/(?<host>[^:]+)/, uri),
        Regex.named_captures(~r/(?<username>[^@]+)@(?<host>[^:]+):(?<path>.+)/, uri)
      ]
      |> Enum.filter(fn
        nil -> false
        _ -> true
      end)

    case scp do
      [] ->
        Mix.raise("Getting url for git repo failed")

      # Explicitly transform an https url with a username and password to one that uses
      # ssh instead to handle issues where CI runners checkout via https with a token
      # but everyone else does via ssh
      [%{"proto" => "https", "host" => host, "path" => path, "username" => _username} | _] ->
        "git://git@#{host}/#{path};protocol=ssh;nobranch=1;branch=#{branch}"

      [%{"host" => host, "path" => path, "username" => username}] ->
        "git://#{username}@#{host}/#{path};protocol=ssh;nobranch=1;branch=#{branch}"

      [%{"host" => host, "path" => path}] ->
        "git://#{host}/#{path};branch=#{branch}"

      [%{"host" => host}] ->
        "git://#{String.trim(host)};branch=#{branch}"
    end
  end

  defp git_ref(_dir) do
    ["rev-parse", "HEAD"]
    |> git!()
    |> parse_ref()
  end

  defp parse_ref(ref) do
    ref |> String.trim("\n")
  end

  defp template(target, assigns, template \\ "bitbake.eex") do
    Application.app_dir(:mix_bitbake, Path.join("priv", "templates"))
    |> Path.join(template)
    |> copy_template(target, assigns)
  end

  defp copy_template(source, target, assigns) do
    File.mkdir_p!(Path.dirname(target))
    File.write!(target, EEx.eval_file(source, assigns: assigns))
  end

  defp get_md5(license_file_path) do
    data = File.read!(license_file_path)
    digest = :crypto.hash(:md5, data)
    Base.encode16(digest, case: :lower)
  end

  defp git!(args) do
    opts = cmd_opts(into: "", stderr_to_stdout: true)

    case System.cmd("git", args, opts) do
      {response, 0} ->
        response

      {response, _} ->
        Mix.raise("Command \"git #{Enum.join(args, " ")}\" failed with reason: #{response}")
    end
  end

  defp cmd_opts(opts) do
    case File.cwd() do
      {:ok, cwd} -> Keyword.put(opts, :cd, cwd)
      _ -> opts
    end
  end
end
