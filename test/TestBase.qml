Object {
    id: tb
    property Object parent: nil
    property Object p1: nil
    property Object p2: tb.p1
    property Object p3: tb.p2

    //Needed for testing the parent reference
    property Array children: []

    function to_s()
    {
        "{#{p1},#{p2},#{p3}}"
    }
}
