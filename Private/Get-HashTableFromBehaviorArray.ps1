# Transform an array of config behaviors to a hash table where the key is the path
# specified in the behavior and the value is the behavior object.
# Example:
# Assets:
#   - Path: "/tenancy"
#   - Path: "/yada"
#     Suffix: "1234"
# becomes
#  behaviors["/tenancy"] = @{ Path = "/tenancy" }
#  behaviors["/yada"] = @{ Path = "/yada", Suffix = "1234" }
function Get-HashTableFromBehaviorArray($BehaviorArray) {
    $BehaviorHash = @{}
    foreach($Behavior in $BehaviorArray) {
        $BehaviorHash[$Behavior.Path] = $Behavior
    }
    return $BehaviorHash
}