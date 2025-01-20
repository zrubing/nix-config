# Turn each table row into a key-value pair using two column names and merge them into a record.
export def untranspose [
  key: cell-path   # Column to use as keys in the record
  value: cell-path # Column to use as value in the record
]: [table -> record] {
  reduce -f {} { |row record| $record | upsert ($row | get $key) ($row | get $value)}
}

# Apply a block to the input value and return the result if the condition is true,
# otherwise return the input value unchanged.
export def apply-if [
  cond: bool # Condition to check for
  block: any # Block to conditionally apply to the input value
]: [any -> any] {
  let value = $in

  if $cond {
    ($value | do $block)
  } else {
    $value
  }
}
