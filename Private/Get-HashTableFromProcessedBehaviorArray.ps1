function Get-HashTableFromProcessedBehaviorArray($BehaviorArray) {
    $BehaviorHash = @{}
    foreach($Behavior in $BehaviorArray) {
        $BehaviorHash[$Behavior[0]] = $Behavior
    }
    return $BehaviorHash
}