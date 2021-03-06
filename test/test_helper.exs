parse_version = fn version ->
  destructure [major, minor], String.split(version, ".")
  {String.to_integer(major), String.to_integer(minor || "0")}
end

pg_version =
  case System.get_env("PGVERSION") do
    nil -> nil
    version -> parse_version.(version)
  end

crdb_version =
  case System.get_env("CDBVERSION") do
    nil -> nil
    version -> parse_version.(version)
  end

pg_flavor =
  case System.get_env("PGFLAVOR") do
    nil -> :postgresql
    "postgresql" -> :postgresql
    "cockroachdb" -> :cockroachdb
  end

otp_release = :otp_release |> :erlang.system_info() |> List.to_integer()
unix_socket_dir = System.get_env("PG_SOCKET_DIR") || "/tmp"
port = System.get_env("PGPORT") || "5432"
unix_socket_path = Path.join(unix_socket_dir, ".s.PGSQL.#{port}")
unix_exclude = if otp_release >= 20 and File.exists?(unix_socket_path) do
  []
else
  [unix: true]
end

notify_exclude = if pg_version == {8, 4} do
  [requires_notify_payload: true]
else
  []
end

version_exclusions = case pg_flavor do
  :postgresql ->
    [min_pg_version: nil] ++
    if pg_version do
      [{8, 4}, {9, 0}, {9, 1}, {9, 2}, {9, 3}, {9, 4}, {9, 5}]
      |> Enum.filter(fn x -> x > pg_version end)
      |> Enum.map(fn {major, minor} -> {:min_pg_version, "#{major}.#{minor}"} end)
    else
      []
    end

  :cockroachdb ->
    [min_crdb_version: nil] ++
    if crdb_version do
      [{2, 1}]
      |> Enum.filter(fn x -> x > crdb_version end)
      |> Enum.map(fn {major, minor} -> {:min_crdb_version, "#{major}.#{minor}"} end)
    else
      []
    end
end

ExUnit.start(exclude: version_exclusions ++ notify_exclude ++ unix_exclude)

{:ok, _} = :application.ensure_all_started(:crypto)

run_cmd = fn cmd ->
  key = :ecto_setup_cmd_output
  Process.put(key, "")
  status = Mix.Shell.cmd(cmd, fn(data) ->
    current = Process.get(key)
    Process.put(key, current <> data)
  end)
  output = Process.get(key)
  Process.put(key, "")
  {status, output}
end

sql = """
DROP TABLE IF EXISTS composite1;
CREATE TABLE composite1 (a int, b text);

DROP TABLE IF EXISTS composite2;
CREATE TABLE composite2 (a int, b int, c int);

CREATE TABLE uniques (a int UNIQUE);

DROP TABLE IF EXISTS missing_oid;

CREATE TABLE altering (a int2);

CREATE TABLE calendar (a timestamp without time zone, b timestamp with time zone);
"""

sql_roles = """
DROP ROLE IF EXISTS postgrex_cleartext_pw;
DROP ROLE IF EXISTS postgrex_md5_pw;

CREATE USER postgrex_cleartext_pw WITH PASSWORD 'postgrex_cleartext_pw';
CREATE USER postgrex_md5_pw WITH PASSWORD 'postgrex_md5_pw';
"""

sql_types = """
DROP TYPE IF EXISTS enum1;
CREATE TYPE enum1 AS ENUM ('elixir', 'erlang');

DROP TYPE IF EXISTS missing_enum;
DROP TYPE IF EXISTS missing_comp;
"""

sql_domains = """
DROP DOMAIN IF EXISTS points_domain;
CREATE DOMAIN points_domain AS point[] CONSTRAINT is_populated CHECK (COALESCE(array_length(VALUE, 1), 0) >= 1);

DROP DOMAIN IF EXISTS floats_domain;
CREATE DOMAIN floats_domain AS float[] CONSTRAINT is_populated CHECK (COALESCE(array_length(VALUE, 1), 0) >= 1);
"""

sql_with_schemas = """
DROP SCHEMA IF EXISTS test;
CREATE SCHEMA test;
"""

cmds = [
  ["-c", "DROP DATABASE IF EXISTS postgrex_test;"],
  ["-c", "DROP DATABASE IF EXISTS postgrex_test_with_schemas;"],
  ["-c", "CREATE DATABASE postgrex_test TEMPLATE=template0 ENCODING='UTF8' LC_COLLATE='C.UTF-8' LC_CTYPE='C.UTF-8';"],
  ["-c", "CREATE DATABASE postgrex_test_with_schemas TEMPLATE=template0 ENCODING='UTF8' LC_COLLATE='C.UTF-8' LC_CTYPE='C.UTF-8';"],
  ["-d", "postgrex_test", "-c", sql]
]

postgresql_cmds = [
  ["-d", "postgrex_test", "-c", sql_roles],
  ["-d", "postgrex_test", "-c", sql_types],
  ["-d", "postgrex_test", "-c", sql_domains],
  ["-d", "postgrex_test_with_schemas", "-c", sql_with_schemas]
]

pg_path = System.get_env("PGPATH")

cmds =
  cond do
    pg_flavor == :cockroachdb ->
      cmds
    !pg_version || pg_version >= {9, 1} ->
      cmds ++ postgresql_cmds ++
        [["-d", "postgrex_test_with_schemas", "-c", "CREATE EXTENSION IF NOT EXISTS hstore WITH SCHEMA test;"],
         ["-d", "postgrex_test", "-c", "CREATE EXTENSION IF NOT EXISTS hstore;"]]
    pg_version == {9, 0} ->
      cmds ++ postgresql_cmds ++ [["-d", "postgrex_test", "-f", "#{pg_path}/contrib/hstore.sql"]]
    pg_version < {9, 0} ->
      cmds ++ postgresql_cmds ++ [["-d", "postgrex_test", "-c", "CREATE LANGUAGE plpgsql;"]]
    true ->
      cmds ++ postgresql_cmds
end

superuser = case System.get_env("PGSUPERUSER") do
  nil ->
    case pg_flavor do
      :postgresql  -> "postgres"
      :cockroachdb -> "root"
    end
  user -> user
end
psql_env = Map.put_new(System.get_env(), "PGUSER", superuser)

Enum.each(cmds, fn args ->
  {output, status} = System.cmd("psql", args, stderr_to_stdout: true, env: psql_env)

  if status != 0 do
    IO.puts """
    Command:

    psql #{Enum.join(args, " ")}

    error'd with:

    #{output}

    Please verify the user "postgres" exists and it has permissions to
    create databases and users. If not, you can create a new user with:

    $ createuser postgres -s --no-password
    """
    System.halt(1)
  end
end)

defmodule Postgrex.TestHelper do
  defmacro query(stat, params, opts \\ []) do
    quote do
      case Postgrex.query(var!(context)[:pid], unquote(stat),
                                     unquote(params), unquote(opts)) do
        {:ok, %Postgrex.Result{rows: nil}} -> :ok
        {:ok, %Postgrex.Result{rows: rows}} -> rows
        {:error, %Postgrex.Error{} = err} -> err
      end
    end
  end

  defmacro prepare(name, stat, opts \\ []) do
    quote do
      case Postgrex.prepare(var!(context)[:pid], unquote(name),
                                     unquote(stat), unquote(opts)) do
        {:ok, %Postgrex.Query{} = query} -> query
        {:error, %Postgrex.Error{} = err} -> err
      end
    end
  end

  defmacro execute(query, params, opts \\ []) do
    quote do
      case Postgrex.execute(var!(context)[:pid], unquote(query),
                                       unquote(params), unquote(opts)) do
        {:ok, %Postgrex.Result{rows: nil}} -> :ok
        {:ok, %Postgrex.Result{rows: rows}} -> rows
        {:error, %Postgrex.Error{} = err} -> err
      end
    end
  end

  defmacro stream(query, params, opts \\ []) do
    quote do
      Postgrex.stream(var!(conn), unquote(query), unquote(params), unquote(opts))
    end
  end

  defmacro close(query, opts \\ []) do
    quote do
      case Postgrex.close(var!(context)[:pid], unquote(query),
                                     unquote(opts)) do
        :ok -> :ok
        {:error, %Postgrex.Error{} = err} -> err
      end
    end
  end

  defmacro transaction(fun, opts \\ []) do
    quote do
      Postgrex.transaction(var!(context)[:pid], unquote(fun),
                                      unquote(opts))
    end
  end
end
