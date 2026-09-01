defmodule Muex.Config.Internal do
  @moduledoc false

  @type t :: %__MODULE__{
          changed_diff_file: Path.t() | nil,
          checkpoint: Path.t() | nil,
          coverage_index_file: Path.t() | nil,
          inventory_cache_file: Path.t() | nil,
          inventory_cache_key: String.t() | nil
        }

  defstruct [
    :changed_diff_file,
    :checkpoint,
    :coverage_index_file,
    :inventory_cache_file,
    :inventory_cache_key
  ]
end
