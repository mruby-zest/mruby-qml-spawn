TestBase {
    id: te1

    TestBase {
        id: te2
        function to_s()
        {
            "TE2"
        }
    }

    TestBase {
        id: te3
        p2: 5
    }

    TestBase {
        id: te4
        p1: te4.tramp

        function tramp()
        {
            te1.p1
        }
    }

    function to_s()
    {
        "["+self.inspect+","+te2.to_s+","+te3.to_s+"]"
    }
}
