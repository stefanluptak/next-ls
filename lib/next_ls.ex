defmodule NextLS do
  @moduledoc false
  use GenLSP

  import NextLS.DB.Query

  alias GenLSP.Enumerations.ErrorCodes
  alias GenLSP.Enumerations.TextDocumentSyncKind
  alias GenLSP.ErrorResponse
  alias GenLSP.Notifications.Exit
  alias GenLSP.Notifications.Initialized
  alias GenLSP.Notifications.TextDocumentDidChange
  alias GenLSP.Notifications.TextDocumentDidOpen
  alias GenLSP.Notifications.TextDocumentDidSave
  alias GenLSP.Notifications.WorkspaceDidChangeWatchedFiles
  alias GenLSP.Notifications.WorkspaceDidChangeWorkspaceFolders
  alias GenLSP.Requests.Initialize
  alias GenLSP.Requests.Shutdown
  alias GenLSP.Requests.TextDocumentDefinition
  alias GenLSP.Requests.TextDocumentDocumentSymbol
  alias GenLSP.Requests.TextDocumentFormatting
  alias GenLSP.Requests.TextDocumentHover
  alias GenLSP.Requests.TextDocumentReferences
  alias GenLSP.Requests.WorkspaceSymbol
  alias GenLSP.Structures.DidChangeWatchedFilesParams
  alias GenLSP.Structures.DidChangeWorkspaceFoldersParams
  alias GenLSP.Structures.DidOpenTextDocumentParams
  alias GenLSP.Structures.InitializeParams
  alias GenLSP.Structures.InitializeResult
  alias GenLSP.Structures.Location
  alias GenLSP.Structures.Position
  alias GenLSP.Structures.Range
  alias GenLSP.Structures.SaveOptions
  alias GenLSP.Structures.ServerCapabilities
  alias GenLSP.Structures.SymbolInformation
  alias GenLSP.Structures.TextDocumentItem
  alias GenLSP.Structures.TextDocumentSyncOptions
  alias GenLSP.Structures.TextEdit
  alias GenLSP.Structures.WorkspaceFoldersChangeEvent
  alias NextLS.DB
  alias NextLS.Definition
  alias NextLS.DiagnosticCache
  alias NextLS.Progress
  alias NextLS.Runtime

  def start_link(args) do
    {args, opts} =
      Keyword.split(args, [
        :cache,
        :auto_update,
        :task_supervisor,
        :runtime_task_supervisor,
        :dynamic_supervisor,
        :extensions,
        :registry
      ])

    GenLSP.start_link(__MODULE__, args, opts)
  end

  @impl true
  def init(lsp, args) do
    task_supervisor = Keyword.fetch!(args, :task_supervisor)
    runtime_task_supervisor = Keyword.fetch!(args, :runtime_task_supervisor)
    dynamic_supervisor = Keyword.fetch!(args, :dynamic_supervisor)

    registry = Keyword.fetch!(args, :registry)

    extensions = Keyword.get(args, :extensions, [NextLS.ElixirExtension, NextLS.CredoExtension])
    cache = Keyword.fetch!(args, :cache)
    {:ok, logger} = DynamicSupervisor.start_child(dynamic_supervisor, {NextLS.Logger, lsp: lsp})

    {:ok,
     assign(lsp,
       auto_update: Keyword.get(args, :auto_update, false),
       exit_code: 1,
       documents: %{},
       refresh_refs: %{},
       cache: cache,
       logger: logger,
       task_supervisor: task_supervisor,
       runtime_task_supervisor: runtime_task_supervisor,
       dynamic_supervisor: dynamic_supervisor,
       registry: registry,
       extensions: extensions,
       ready: false,
       client_capabilities: nil
     )}
  end

  @impl true
  def handle_request(
        %Initialize{
          params: %InitializeParams{
            root_uri: root_uri,
            workspace_folders: workspace_folders,
            capabilities: caps,
            initialization_options: init_opts
          }
        },
        lsp
      ) do
    workspace_folders =
      if caps.workspace.workspace_folders do
        workspace_folders
      else
        [%{name: Path.basename(root_uri), uri: root_uri}]
      end

    {:ok, init_opts} = __MODULE__.InitOpts.validate(init_opts)

    {:reply,
     %InitializeResult{
       capabilities: %ServerCapabilities{
         text_document_sync: %TextDocumentSyncOptions{
           open_close: true,
           save: %SaveOptions{include_text: true},
           change: TextDocumentSyncKind.full()
         },
         document_formatting_provider: true,
         hover_provider: true,
         workspace_symbol_provider: true,
         document_symbol_provider: true,
         references_provider: true,
         definition_provider: true,
         workspace: %{
           workspace_folders: %GenLSP.Structures.WorkspaceFoldersServerCapabilities{
             supported: true,
             change_notifications: true
           }
         }
       },
       server_info: %{name: "Next LS"}
     },
     assign(lsp,
       root_uri: root_uri,
       workspace_folders: workspace_folders,
       client_capabilities: caps,
       init_opts: init_opts
     )}
  end

  def handle_request(%TextDocumentDefinition{params: %{text_document: %{uri: uri}, position: position}}, lsp) do
    result =
      dispatch(lsp.assigns.registry, :databases, fn entries ->
        for {pid, _} <- entries do
          case Definition.fetch(URI.parse(uri).path, {position.line + 1, position.character + 1}, pid) do
            nil ->
              case NextLS.ASTHelpers.Variables.get_variable_definition(
                     URI.parse(uri).path,
                     {position.line + 1, position.character + 1}
                   ) do
                {_name, {startl..endl, startc..endc}} ->
                  %Location{
                    uri: "file://#{URI.parse(uri).path}",
                    range: %Range{
                      start: %Position{
                        line: startl - 1,
                        character: startc - 1
                      },
                      end: %Position{
                        line: endl - 1,
                        character: endc - 1
                      }
                    }
                  }

                _other ->
                  nil
              end

            [] ->
              nil

            [[_pk, _mod, file, _type, _name, line, column | _] | _] ->
              %Location{
                uri: "file://#{file}",
                range: %Range{
                  start: %Position{
                    line: line - 1,
                    character: column - 1
                  },
                  end: %Position{
                    line: line - 1,
                    character: column - 1
                  }
                }
              }
          end
        end
      end)

    {:reply, List.first(result), lsp}
  end

  def handle_request(%TextDocumentDocumentSymbol{params: %{text_document: %{uri: uri}}}, lsp) do
    symbols =
      if Path.extname(uri) in [".ex", ".exs"] do
        try do
          lsp.assigns.documents[uri]
          |> Enum.join("\n")
          |> NextLS.DocumentSymbol.fetch()
        rescue
          e ->
            GenLSP.error(lsp, Exception.format_banner(:error, e, __STACKTRACE__))
            nil
        end
      else
        nil
      end

    {:reply, symbols, lsp}
  end

  # TODO handle `context: %{includeDeclaration: true}` to include the current symbol definition among
  # the results.
  def handle_request(%TextDocumentReferences{params: %{position: position, text_document: %{uri: uri}}}, lsp) do
    file = URI.parse(uri).path
    line = position.line + 1
    col = position.character + 1

    locations =
      dispatch(lsp.assigns.registry, :databases, fn databases ->
        Enum.flat_map(databases, fn {database, _} ->
          references =
            case symbol_info(file, line, col, database) do
              {:function, module, function} ->
                DB.query(
                  database,
                  ~Q"""
                  SELECT file, start_line, end_line, start_column, end_column
                  FROM "references" as refs
                  WHERE refs.identifier = ?
                    AND refs.type = ?
                    AND refs.module = ?
                    AND refs.source = 'user'
                  """,
                  [function, "function", module]
                )

              {:module, module} ->
                DB.query(
                  database,
                  ~Q"""
                  SELECT file, start_line, end_line, start_column, end_column
                  FROM "references" as refs
                  WHERE refs.module = ?
                    AND refs.type = ?
                    AND refs.source = 'user'
                  """,
                  [module, "alias"]
                )

              {:attribute, module, attribute} ->
                DB.query(
                  database,
                  ~Q"""
                  SELECT file, start_line, end_line, start_column, end_column
                  FROM "references" as refs
                  WHERE refs.identifier = ?
                    AND refs.type = ?
                    AND refs.module = ?
                    AND refs.source = 'user'
                  """,
                  [attribute, "attribute", module]
                )

              :unknown ->
                file
                |> NextLS.ASTHelpers.Variables.list_variable_references({line, col})
                |> Enum.map(fn {_name, {startl..endl, startc..endc}} ->
                  [file, startl, endl, startc, endc]
                end)
            end

          for [file, startl, endl, startc, endc] <- references, match?({:ok, _}, File.stat(file)) do
            %Location{
              uri: "file://#{file}",
              range: %Range{
                start: %Position{line: clamp(startl - 1), character: clamp(startc - 1)},
                end: %Position{line: clamp(endl - 1), character: clamp(endc - 1)}
              }
            }
          end
        end)
      end)

    {:reply, locations, lsp}
  end

  def handle_request(%TextDocumentHover{params: %{position: position, text_document: %{uri: uri}}}, lsp) do
    file = URI.parse(uri).path
    line = position.line + 1
    col = position.character + 1

    select = ~w<identifier type module arity start_line start_column end_line end_column>a

    reference_query = ~Q"""
    SELECT :select
    FROM "references" refs
    WHERE refs.file = ?
      AND ? BETWEEN refs.start_line AND refs.end_line
      AND ? BETWEEN refs.start_column AND refs.end_column
    ORDER BY refs.id ASC
    LIMIT 1
    """

    locations =
      dispatch(lsp.assigns.registry, :databases, fn databases ->
        Enum.flat_map(databases, fn {database, _} ->
          DB.query(database, reference_query, args: [file, line, col], select: select)
        end)
      end)

    resp =
      case locations do
        [reference] ->
          mod =
            if reference.module == String.downcase(reference.module) do
              String.to_existing_atom(reference.module)
            else
              Module.concat([reference.module])
            end

          result =
            dispatch(lsp.assigns.registry, :runtimes, fn entries ->
              [result] =
                for {runtime, %{uri: wuri}} <- entries, String.starts_with?(uri, wuri) do
                  Runtime.call(runtime, {Code, :fetch_docs, [mod]})
                end

              result
            end)

          value =
            with {:ok, {:docs_v1, _, _lang, content_type, %{"en" => mod_doc}, _, fdocs}} <- result do
              case reference.type do
                "alias" ->
                  """
                  ## #{reference.module}

                  #{NextLS.HoverHelpers.to_markdown(content_type, mod_doc)}
                  """

                "function" ->
                  doc =
                    Enum.find(fdocs, fn {{type, name, _a}, _, _, _doc, _} ->
                      type in [:function, :macro] and to_string(name) == reference.identifier
                    end)

                  case doc do
                    {_, _, _, %{"en" => fdoc}, _} ->
                      """
                      ## #{Macro.to_string(mod)}.#{reference.identifier}/#{reference.arity}

                      #{NextLS.HoverHelpers.to_markdown(content_type, fdoc)}
                      """

                    _ ->
                      nil
                  end
              end
            else
              _ -> nil
            end

          with value when is_binary(value) <- value do
            %GenLSP.Structures.Hover{
              contents: %GenLSP.Structures.MarkupContent{
                kind: GenLSP.Enumerations.MarkupKind.markdown(),
                value: String.trim(value)
              },
              range: %Range{
                start: %Position{line: reference.start_line - 1, character: reference.start_column - 1},
                end: %Position{line: reference.end_line - 1, character: reference.end_column - 1}
              }
            }
          end

        _ ->
          nil
      end

    {:reply, resp, lsp}
  end

  def handle_request(%WorkspaceSymbol{params: %{query: query}}, lsp) do
    case_sensitive? = String.downcase(query) != query

    symbols = fn pid ->
      rows =
        DB.query(
          pid,
          ~Q"""
          SELECT *
          FROM symbols
          WHERE source = 'user';
          """,
          []
        )

      for [_pk, module, file, type, name, line, column | _] <- rows do
        %{
          module: module,
          file: file,
          type: type,
          name: name,
          line: line,
          column: column
        }
      end
    end

    symbols =
      dispatch(lsp.assigns.registry, :databases, fn entries ->
        filtered_symbols =
          for {pid, _} <- entries, symbol <- symbols.(pid), score = fuzzy_match(symbol.name, query, case_sensitive?) do
            name =
              if symbol.type not in ["defstruct", "attribute"] do
                "#{symbol.type} #{symbol.name}"
              else
                "#{symbol.name}"
              end

            {%SymbolInformation{
               name: name,
               kind: elixir_kind_to_lsp_kind(symbol.type),
               location: %Location{
                 uri: "file://#{symbol.file}",
                 range: %Range{
                   start: %Position{
                     line: symbol.line - 1,
                     character: symbol.column - 1
                   },
                   end: %Position{
                     line: symbol.line - 1,
                     character: symbol.column - 1
                   }
                 }
               }
             }, score}
          end

        filtered_symbols |> List.keysort(1, :desc) |> Enum.map(&elem(&1, 0))
      end)

    {:reply, symbols, lsp}
  end

  def handle_request(%TextDocumentFormatting{params: %{text_document: %{uri: uri}}}, lsp) do
    document = lsp.assigns.documents[uri]

    [resp] =
      if is_list(document) do
        dispatch(lsp.assigns.registry, :runtimes, fn entries ->
          for {runtime, %{uri: wuri}} <- entries, String.starts_with?(uri, wuri) do
            with {:ok, {formatter, _}} <-
                   Runtime.call(runtime, {Mix.Tasks.Format, :formatter_for_file, [URI.parse(uri).path]}),
                 {:ok, response} when is_binary(response) or is_list(response) <-
                   Runtime.call(runtime, {Kernel, :apply, [formatter, [Enum.join(document, "\n")]]}) do
              {:reply,
               [
                 %TextEdit{
                   new_text: IO.iodata_to_binary(response),
                   range: %Range{
                     start: %Position{line: 0, character: 0},
                     end: %Position{
                       line: length(document),
                       character: document |> List.last() |> String.length() |> Kernel.-(1) |> max(0)
                     }
                   }
                 }
               ], lsp}
            else
              {:error, :not_ready} ->
                GenLSP.notify(lsp, %GenLSP.Notifications.WindowShowMessage{
                  params: %GenLSP.Structures.ShowMessageParams{
                    type: GenLSP.Enumerations.MessageType.info(),
                    message: "The NextLS runtime is still initializing!"
                  }
                })

                {:reply, nil, lsp}

              _ ->
                GenLSP.warning(lsp, "[Next LS] Failed to format the file: #{uri}")

                {:reply, nil, lsp}
            end
          end
        end)
      else
        GenLSP.warning(
          lsp,
          "[Next LS] The file #{uri} was not found in the server's process state. Something must have gone wrong when opening, changing, or saving the file."
        )

        [{:reply, nil, lsp}]
      end

    resp
  end

  def handle_request(%Shutdown{}, lsp) do
    {:reply, nil, assign(lsp, exit_code: 0)}
  end

  def handle_request(%{method: method}, lsp) do
    GenLSP.warning(lsp, "[NextLS] Method Not Found: #{method}")

    {:reply,
     %ErrorResponse{
       code: ErrorCodes.method_not_found(),
       message: "Method Not Found: #{method}"
     }, lsp}
  end

  @impl true
  def handle_notification(%Initialized{}, lsp) do
    GenLSP.log(lsp, "[NextLS] NextLS v#{version()} has initialized!")

    with opts when is_list(opts) <- lsp.assigns.auto_update do
      {:ok, _} =
        DynamicSupervisor.start_child(
          lsp.assigns.dynamic_supervisor,
          {NextLS.Updater, Keyword.merge(opts, logger: lsp.assigns.logger)}
        )
    end

    for extension <- lsp.assigns.extensions do
      {:ok, _} =
        DynamicSupervisor.start_child(
          lsp.assigns.dynamic_supervisor,
          {extension,
           cache: lsp.assigns.cache,
           registry: lsp.assigns.registry,
           publisher: self(),
           task_supervisor: lsp.assigns.runtime_task_supervisor}
        )
    end

    with %{dynamic_registration: true} <- lsp.assigns.client_capabilities.workspace.did_change_watched_files do
      nil =
        GenLSP.request(lsp, %GenLSP.Requests.ClientRegisterCapability{
          id: System.unique_integer([:positive]),
          params: %GenLSP.Structures.RegistrationParams{
            registrations: [
              %GenLSP.Structures.Registration{
                id: "file-watching",
                method: "workspace/didChangeWatchedFiles",
                register_options: %GenLSP.Structures.DidChangeWatchedFilesRegistrationOptions{
                  watchers:
                    for ext <- ~W|ex exs leex eex heex sface| do
                      %GenLSP.Structures.FileSystemWatcher{kind: 7, glob_pattern: "**/*.#{ext}"}
                    end
                }
              }
            ]
          }
        })
    end

    GenLSP.log(lsp, "[NextLS] Booting runtimes...")

    for %{uri: uri, name: name} <- lsp.assigns.workspace_folders do
      token = Progress.token()
      Progress.start(lsp, token, "Initializing NextLS runtime for folder #{name}...")
      parent = self()
      working_dir = URI.parse(uri).path

      {:ok, _} =
        DynamicSupervisor.start_child(
          lsp.assigns.dynamic_supervisor,
          {NextLS.Runtime.Supervisor,
           path: Path.join(working_dir, ".elixir-tools"),
           name: name,
           lsp: lsp,
           registry: lsp.assigns.registry,
           logger: lsp.assigns.logger,
           runtime: [
             task_supervisor: lsp.assigns.runtime_task_supervisor,
             working_dir: working_dir,
             uri: uri,
             mix_env: lsp.assigns.init_opts.mix_env,
             mix_target: lsp.assigns.init_opts.mix_target,
             on_initialized: fn status ->
               if status == :ready do
                 Progress.stop(lsp, token, "NextLS runtime for folder #{name} has initialized!")
                 GenLSP.log(lsp, "[NextLS] Runtime for folder #{name} is ready...")

                 msg = {:runtime_ready, name, self()}

                 dispatch(lsp.assigns.registry, :extensions, fn entries ->
                   for {pid, _} <- entries, do: send(pid, msg)
                 end)

                 send(parent, msg)
               else
                 Progress.stop(lsp, token)
                 GenLSP.error(lsp, "[NextLS] Runtime for folder #{name} failed to initialize")
               end
             end,
             logger: lsp.assigns.logger
           ]}
        )
    end

    {:noreply, lsp}
  end

  def handle_notification(%TextDocumentDidSave{}, %{assigns: %{ready: false}} = lsp) do
    {:noreply, lsp}
  end

  # TODO: add some test cases for saving files in multiple workspaces
  def handle_notification(
        %TextDocumentDidSave{
          params: %GenLSP.Structures.DidSaveTextDocumentParams{text: text, text_document: %{uri: uri}}
        },
        %{assigns: %{ready: true}} = lsp
      ) do
    for task <- Task.Supervisor.children(lsp.assigns.task_supervisor) do
      Process.exit(task, :kill)
    end

    refresh_refs =
      dispatch(lsp.assigns.registry, :runtimes, fn entries ->
        for {pid, %{name: name, uri: wuri}} <- entries, String.starts_with?(uri, wuri), into: %{} do
          token = Progress.token()
          Progress.start(lsp, token, "Compiling #{name}...")

          task =
            Task.Supervisor.async_nolink(lsp.assigns.task_supervisor, fn ->
              {name, Runtime.compile(pid)}
            end)

          {task.ref, {token, "Compiled #{name}!"}}
        end
      end)

    {:noreply,
     lsp
     |> then(&put_in(&1.assigns.documents[uri], String.split(text, "\n")))
     |> then(&put_in(&1.assigns.refresh_refs, refresh_refs))}
  end

  def handle_notification(%TextDocumentDidChange{}, %{assigns: %{ready: false}} = lsp) do
    {:noreply, lsp}
  end

  def handle_notification(
        %TextDocumentDidChange{params: %{text_document: %{uri: uri}, content_changes: [%{text: text}]}},
        lsp
      ) do
    for task <- Task.Supervisor.children(lsp.assigns.task_supervisor) do
      Process.exit(task, :kill)
    end

    {:noreply, put_in(lsp.assigns.documents[uri], String.split(text, "\n"))}
  end

  def handle_notification(
        %TextDocumentDidOpen{
          params: %DidOpenTextDocumentParams{text_document: %TextDocumentItem{text: text, uri: uri}}
        },
        lsp
      ) do
    {:noreply, put_in(lsp.assigns.documents[uri], String.split(text, "\n"))}
  end

  def handle_notification(
        %WorkspaceDidChangeWorkspaceFolders{
          params: %DidChangeWorkspaceFoldersParams{event: %WorkspaceFoldersChangeEvent{added: added, removed: removed}}
        },
        lsp
      ) do
    dispatch(lsp.assigns.registry, :runtime_supervisors, fn entries ->
      names = Enum.map(entries, fn {_, %{name: name}} -> name end)

      for %{name: name, uri: uri} <- added, name not in names do
        GenLSP.log(lsp, "[NextLS] Adding workspace folder #{name}")
        token = Progress.token()
        Progress.start(lsp, token, "Initializing NextLS runtime for folder #{name}...")
        parent = self()
        working_dir = URI.parse(uri).path

        # TODO: probably extract this to the Runtime module
        {:ok, _} =
          DynamicSupervisor.start_child(
            lsp.assigns.dynamic_supervisor,
            {NextLS.Runtime.Supervisor,
             path: Path.join(working_dir, ".elixir-tools"),
             name: name,
             registry: lsp.assigns.registry,
             runtime: [
               task_supervisor: lsp.assigns.runtime_task_supervisor,
               working_dir: working_dir,
               uri: uri,
               mix_env: lsp.assigns.init_opts.mix_env,
               mix_target: lsp.assigns.init_opts.mix_target,
               on_initialized: fn status ->
                 if status == :ready do
                   Progress.stop(lsp, token, "NextLS runtime for folder #{name} has initialized!")
                   GenLSP.log(lsp, "[NextLS] Runtime for folder #{name} is ready...")
                   msg = {:runtime_ready, name, self()}

                   dispatch(lsp.assigns.registry, :extensions, fn entries ->
                     for {pid, _} <- entries, do: send(pid, msg)
                   end)

                   send(parent, msg)
                 else
                   Progress.stop(lsp, token)
                   GenLSP.error(lsp, "[NextLS] Runtime for folder #{name} failed to initialize")
                 end
               end,
               logger: lsp.assigns.logger
             ]}
          )
      end

      names = Enum.map(removed, & &1.name)

      for {pid, %{name: name}} <- entries, name in names do
        GenLSP.log(lsp, "[NextLS] Removing workspace folder #{name}")
        # TODO: probably extract this to the Runtime module
        DynamicSupervisor.terminate_child(lsp.assigns.dynamic_supervisor, pid)
      end
    end)

    {:noreply, lsp}
  end

  def handle_notification(%WorkspaceDidChangeWatchedFiles{params: %DidChangeWatchedFilesParams{changes: changes}}, lsp) do
    type = GenLSP.Enumerations.FileChangeType.deleted()

    lsp =
      for %{type: ^type, uri: uri} <- changes, reduce: lsp do
        lsp ->
          dispatch(lsp.assigns.registry, :databases, fn entries ->
            for {pid, _} <- entries do
              file = URI.parse(uri).path

              NextLS.DB.query(
                pid,
                ~Q"""
                DELETE FROM symbols
                WHERE symbols.file = ?;
                """,
                [file]
              )

              NextLS.DB.query(
                pid,
                ~Q"""
                DELETE FROM 'references' AS refs
                WHERE refs.file = ?;
                """,
                [file]
              )
            end
          end)

          update_in(lsp.assigns.documents, &Map.drop(&1, [uri]))
      end

    {:noreply, lsp}
  end

  def handle_notification(%Exit{}, lsp) do
    System.halt(lsp.assigns.exit_code)

    {:noreply, lsp}
  end

  def handle_notification(_notification, lsp) do
    {:noreply, lsp}
  end

  def handle_info(:publish, lsp) do
    all =
      for {_namespace, cache} <- DiagnosticCache.get(lsp.assigns.cache), {file, diagnostics} <- cache, reduce: %{} do
        d -> Map.update(d, file, diagnostics, fn value -> value ++ diagnostics end)
      end

    for {file, diagnostics} <- all do
      GenLSP.notify(lsp, %GenLSP.Notifications.TextDocumentPublishDiagnostics{
        params: %GenLSP.Structures.PublishDiagnosticsParams{
          uri: "file://#{file}",
          diagnostics: diagnostics
        }
      })
    end

    {:noreply, lsp}
  end

  def handle_info({:runtime_ready, name, runtime_pid}, lsp) do
    token = Progress.token()
    Progress.start(lsp, token, "Compiling #{name}...")

    task =
      Task.Supervisor.async_nolink(lsp.assigns.task_supervisor, fn ->
        {_, %{mode: mode}} =
          dispatch(lsp.assigns.registry, :databases, fn entries ->
            Enum.find(entries, fn {_, %{runtime: runtime}} -> runtime == name end)
          end)

        {name, Runtime.compile(runtime_pid, force: mode == :reindex)}
      end)

    refresh_refs = Map.put(lsp.assigns.refresh_refs, task.ref, {token, "Compiled #{name}!"})

    {:noreply, assign(lsp, ready: true, refresh_refs: refresh_refs)}
  end

  def handle_info({ref, _resp}, %{assigns: %{refresh_refs: refs}} = lsp) when is_map_key(refs, ref) do
    Process.demonitor(ref, [:flush])
    {{token, msg}, refs} = Map.pop(refs, ref)

    Progress.stop(lsp, token, msg)

    {:noreply, assign(lsp, refresh_refs: refs)}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{assigns: %{refresh_refs: refs}} = lsp)
      when is_map_key(refs, ref) do
    {{token, _}, refs} = Map.pop(refs, ref)

    Progress.stop(lsp, token)

    {:noreply, assign(lsp, refresh_refs: refs)}
  end

  def handle_info(message, lsp) do
    GenLSP.log(lsp, "[NextLS] Unhandled message: #{inspect(message)}")
    {:noreply, lsp}
  end

  def version do
    case :application.get_key(:next_ls, :vsn) do
      {:ok, version} -> to_string(version)
      _ -> "dev"
    end
  end

  defp elixir_kind_to_lsp_kind("defmodule"), do: GenLSP.Enumerations.SymbolKind.module()
  defp elixir_kind_to_lsp_kind("defstruct"), do: GenLSP.Enumerations.SymbolKind.struct()
  defp elixir_kind_to_lsp_kind("attribute"), do: GenLSP.Enumerations.SymbolKind.property()

  defp elixir_kind_to_lsp_kind(kind) when kind in ["def", "defp", "defmacro", "defmacrop"],
    do: GenLSP.Enumerations.SymbolKind.function()

  # NOTE: this is only possible because the registry is not partitioned
  # if it is partitioned, then the callback is called multiple times
  # and this method of extracting the result doesn't really make sense
  defp dispatch(registry, key, callback) do
    ref = make_ref()
    me = self()

    Registry.dispatch(registry, key, fn entries ->
      result = callback.(entries)

      send(me, {ref, result})
    end)

    receive do
      {^ref, result} -> result
    end
  end

  defp symbol_info(file, line, col, database) do
    definition_query = ~Q"""
    SELECT module, type, name
    FROM "symbols" sym
    WHERE sym.file = ?
      AND sym.line = ?
    ORDER BY sym.id ASC
    LIMIT 1
    """

    reference_query = ~Q"""
    SELECT identifier, type, module
    FROM "references" refs
    WHERE refs.file = ?
      AND ? BETWEEN refs.start_line AND refs.end_line
      AND ? BETWEEN refs.start_column AND refs.end_column
    ORDER BY refs.id ASC
    LIMIT 1
    """

    case DB.query(database, definition_query, [file, line]) do
      [[module, "defmodule", _]] ->
        {:module, module}

      [[module, "defstruct", _]] ->
        {:module, module}

      [[module, "def", function]] ->
        {:function, module, function}

      [[module, "defp", function]] ->
        {:function, module, function}

      [[module, "defmacro", function]] ->
        {:function, module, function}

      [[module, "attribute", attribute]] ->
        {:attribute, module, attribute}

      _unknown_definition ->
        case DB.query(database, reference_query, [file, line, col]) do
          [[function, "function", module]] ->
            {:function, module, function}

          [[attribute, "attribute", module]] ->
            {:attribute, module, attribute}

          [[_alias, "alias", module]] ->
            {:module, module}

          _unknown_reference ->
            :unknown
        end
    end
  end

  defp clamp(line), do: max(line, 0)

  # This is an implementation of a sequential fuzzy string matching algorithm,
  # similar to those used in code editors like Sublime Text.
  # It is based on Forrest Smith's work on https://github.com/forrestthewoods/lib_fts/)
  # and his blog post https://www.forrestthewoods.com/blog/reverse_engineering_sublime_texts_fuzzy_match/.
  #
  # Function checks if letters from the query present in the source in correct order.
  # It calculates match score only for matching sources.

  defp fuzzy_match(_source, "", _case_sensitive), do: 1

  defp fuzzy_match(source, query, case_sensitive) do
    source_converted = if case_sensitive, do: source, else: String.downcase(source)
    source_letters = String.codepoints(source_converted)
    query_letters = String.codepoints(query)

    if do_fuzzy_match?(source_letters, query_letters) do
      source_anycase = String.codepoints(source)
      source_downcase = query |> String.downcase() |> String.codepoints()

      calc_match_score(source_anycase, source_downcase, %{leading: true, separator: true}, 0)
    else
      false
    end
  end

  defp do_fuzzy_match?(_source_letters, []), do: true

  defp do_fuzzy_match?(source_letters, [query_head | query_rest]) do
    case match_letter(source_letters, query_head) do
      :no_match -> false
      rest_source_letters -> do_fuzzy_match?(rest_source_letters, query_rest)
    end
  end

  defp match_letter([], _query_letter), do: :no_match

  defp match_letter([source_letter | source_rest], query_letter) when query_letter == source_letter, do: source_rest

  defp match_letter([_ | source_rest], query_letter), do: match_letter(source_rest, query_letter)

  defp calc_match_score(_source_letters, [], _traits, score), do: score

  defp calc_match_score(source_letters, [query_letter | query_rest], traits, score) do
    {rest_source_letters, new_traits, new_score} = calc_letter_score(source_letters, query_letter, traits, score)

    calc_match_score(rest_source_letters, query_rest, new_traits, new_score)
  end

  defp calc_letter_score([source_letter | source_rest], query_letter, traits, score) do
    separator? = source_letter in ["_", ".", "-", "/", " "]
    source_letter_downcase = String.downcase(source_letter)
    upper? = source_letter_downcase != source_letter

    if query_letter == source_letter_downcase do
      new_traits = %{matched: true, leading: false, separator: separator?, upper: upper?}
      new_score = calc_matched_bonus(score, traits, new_traits)

      {source_rest, new_traits, new_score}
    else
      new_traits = %{
        matched: false,
        separator: separator?,
        upper: upper?,
        leading: traits.leading
      }

      new_score = calc_unmatched_penalty(score, traits)

      calc_letter_score(source_rest, query_letter, new_traits, new_score)
    end
  end

  # bonus if match occurs after a separator or on the first letter
  defp calc_matched_bonus(score, %{separator: true}, _new_traits), do: score + 30

  # bonus if match is uppercase and previous is lowercase
  defp calc_matched_bonus(score, %{upper: false}, %{upper: true}), do: score + 30

  # bonus for adjacent matches
  defp calc_matched_bonus(score, %{matched: true}, _new_traits), do: score + 15

  defp calc_matched_bonus(score, _traits, _new_traits), do: score

  # penalty applied for every letter in str before the first match
  defp calc_unmatched_penalty(score, %{leading: true}) when score > -15, do: score - 5

  # penalty for unmatched letter
  defp calc_unmatched_penalty(score, _traits), do: score - 1

  defmodule InitOpts do
    @moduledoc false
    import Schematic

    defstruct mix_target: "host", mix_env: "dev"

    def validate(opts) do
      schematic =
        nullable(
          schema(__MODULE__, %{
            optional(:mix_target) => str(),
            optional(:mix_env) => str()
          })
        )

      with {:ok, nil} <- unify(schematic, opts) do
        {:ok, %__MODULE__{}}
      end
    end
  end
end
