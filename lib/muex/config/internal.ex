defmodule Muex.Config.Internal do
  @moduledoc false

  @type t :: %__MODULE__{
          changed_diff_file: Path.t() | nil,
          audit_only: boolean(),
          audit_plan: Path.t() | nil,
          checkpoint: Path.t() | nil,
          coverage_index_file: Path.t() | nil,
          coverage_corpus_fingerprint: String.t() | nil,
          inventory_cache_file: Path.t() | nil,
          inventory_cache_key: String.t() | nil
        }

  defstruct [
    :changed_diff_file,
    :audit_plan,
    :checkpoint,
    :coverage_index_file,
    :coverage_corpus_fingerprint,
    :inventory_cache_file,
    :inventory_cache_key,
    audit_only: false
  ]
end
