open! Core
open! Int.Replace_polymorphic_compare
open  Expect_test_helpers_kernel

let%test_unit "Time_ns.to_date_ofday" =
  assert (does_raise (fun () ->
    Time_ns.to_date_ofday Time_ns.max_value ~zone:Time.Zone.utc));
;;

let%test_module "Core_kernel.Time_ns.Utc.to_date_and_span_since_start_of_day" =
  (module struct
    type time_ns = Time_ns.t [@@deriving compare]
    let sexp_of_time_ns = Core_kernel.Time_ns.Alternate_sexp.sexp_of_t
    ;;

    (* move 1ms off min and max values because [Time_ns]'s boundary checking in functions
       that convert to/from float apparently has some fuzz issues. *)
    let safe_min_value = Time_ns.add Time_ns.min_value Time_ns.Span.microsecond
    let safe_max_value = Time_ns.sub Time_ns.max_value Time_ns.Span.microsecond
    ;;

    let gen =
      let open Quickcheck.Generator.Let_syntax in
      let%map ns_since_epoch =
        Int63.gen_incl
          (Time_ns.to_int63_ns_since_epoch safe_min_value)
          (Time_ns.to_int63_ns_since_epoch safe_max_value)
      in
      Time_ns.of_int63_ns_since_epoch ns_since_epoch
    ;;

    let test f =
      require_does_not_raise [%here] (fun () ->
        Quickcheck.test gen ~f
          ~sexp_of:[%sexp_of: time_ns]
          ~examples:[ safe_min_value; Time_ns.epoch; safe_max_value ])
    ;;

    let%expect_test "Utc.to_date_and_span_since_start_of_day vs Time_ns.to_date_ofday" =
      test (fun time_ns ->
        match Word_size.word_size with
        | W64 ->
          let kernel_date, kernel_span_since_start_of_day =
            Core_kernel.Time_ns.Utc.to_date_and_span_since_start_of_day time_ns
          in
          let kernel_ofday =
            Time_ns.Ofday.of_span_since_start_of_day_exn kernel_span_since_start_of_day
          in
          let core_date, core_ofday = Time_ns.to_date_ofday time_ns ~zone:Time.Zone.utc in
          [%test_result: Date.t * Time_ns.Ofday.t]
            (kernel_date, kernel_ofday)
            ~expect:(core_date, core_ofday)
        | W32 ->
          ());
      [%expect {||}];
    ;;
  end)

let span_gen =
  Quickcheck.Generator.map Int63.gen ~f:Time_ns.Span.of_int63_ns

let span_option_gen =
  let open Quickcheck.Generator in
  weighted_union [
    1.,  singleton Time_ns.Span.Option.none;
    10., filter_map span_gen ~f:(fun span ->
      if Time_ns.Span.Option.some_is_representable span
      then Some (Time_ns.Span.Option.some span)
      else None)
  ]

let span_examples =
  let scales_of unit_of_time =
    match (unit_of_time : Unit_of_time.t) with
    | Nanosecond | Millisecond | Microsecond -> [0; 1; 10; 100; 999]
    | Second | Minute                        -> [0; 1; 10; 59]
    | Hour                                   -> [0; 1; 10; 23]
    | Day                                    -> [0; 1; 10; 100; 1_000; 10_000; 36_500]
  in
  let multiples_of unit_of_time =
    let span = Time_ns.Span.of_unit_of_time unit_of_time in
    List.map (scales_of unit_of_time) ~f:(fun scale ->
      Time_ns.Span.scale_int span scale)
  in
  List.fold Unit_of_time.all ~init:[Time_ns.Span.zero] ~f:(fun spans unit_of_time ->
    List.concat_map spans ~f:(fun span ->
      List.map (multiples_of unit_of_time) ~f:(fun addend ->
        Time_ns.Span.( + ) span addend)))

let span_option_examples =
  Time_ns.Span.Option.none
  :: List.filter_map span_examples ~f:(fun span ->
    if Time_ns.Span.Option.some_is_representable span
    then Some (Time_ns.Span.Option.some span)
    else None)

let ofday_examples =
  let predefined =
    [ Time_ns.Ofday.start_of_day
    ; Time_ns.Ofday.approximate_end_of_day
    ; Time_ns.Ofday.start_of_next_day
    ]
  in
  let spans =
    List.map Unit_of_time.all ~f:(fun unit_of_time ->
      Time_ns.Span.of_unit_of_time unit_of_time)
  in
  let units_since_midnight =
    List.map spans ~f:(fun span ->
      Time_ns.Ofday.add_exn Time_ns.Ofday.start_of_day span)
  in
  let units_before_midnight =
    List.map spans ~f:(fun span ->
      Time_ns.Ofday.sub_exn Time_ns.Ofday.start_of_next_day span)
  in
  (predefined @ units_since_midnight @ units_before_midnight)
  |> List.dedup_and_sort ~compare:Time_ns.Ofday.compare

let zoned_examples =
  let zone_new_york = Time_ns.Zone.find_exn "America/New_York" in
  List.map ofday_examples ~f:(fun example ->
    Time_ns.Ofday.Zoned.create example Time_ns.Zone.utc)
  @
  List.map ofday_examples ~f:(fun example ->
    Time_ns.Ofday.Zoned.create example zone_new_york)

let%test_module "Time_ns.Span.to_string,of_string" =
  (module struct
    let print_nanos string =
      let nanos = Time_ns.Span.to_int63_ns (Time_ns.Span.of_string string) in
      print_endline (Int63.to_string nanos ^ "ns")

    let%expect_test "to_string" =
      let test int64 =
        print_endline
          (Time_ns.Span.to_string (Time_ns.Span.of_int63_ns (Int63.of_int64_exn int64)))
      in
      List.iter ~f:test [
        1_066_651_290_789_012_345L;
        (-86_460_001_001_000L);
        86_399_000_000_000L;
        105L;
      ];
      [%expect {|
        12345d12h1m30.789012345s
        -1d1m1.001ms
        23h59m59s
        105ns |}];
    ;;

    let%expect_test "of_string" =
      let test str =
        print_endline (Time_ns.Span.to_string (Time_ns.Span.of_string str))
      in
      List.iter ~f:test [
        "1s60h7.890d";
        "+1s60h7.890d";
        "0.0005us";
        "+0.0005us";
        "-0.0005us";
        "0.49ns0.00049us";
      ];
      [%expect {|
        10d9h21m37s
        10d9h21m37s
        1ns
        1ns
        0s
        0s |}]
    ;;

    let%expect_test "round-trip" =
      let test span =
        let string = Time_ns.Span.to_string span in
        let round_trip = Time_ns.Span.of_string string in
        require_equal [%here] (module Time_ns.Span) span round_trip
      in
      quickcheck [%here] span_gen
        ~sexp_of:Time_ns.Span.sexp_of_t
        ~examples:span_examples
        ~f:test;
      [%expect {||}];
    ;;

    let%expect_test "of_string: no allocation" [@tags "64-bits-only"] =
      let test string =
        ignore
          (require_no_allocation [%here] (fun () ->
             Time_ns.Span.of_string string)
           : Time_ns.Span.t)
      in
      quickcheck [%here]
        (Quickcheck.Generator.map span_gen ~f:Time_ns.Span.to_string)
        ~sexp_of:String.sexp_of_t
        ~f:test
        ~examples:[
          "12d34h56m78.123456789898989s";
          "1.234567891234ms";
          "1.234567891234us";
          "1.234567891234ns";
        ];
      [%expect {||}];
    ;;

    let%expect_test "of_string: round to nearest ns" =
      (* Convert the golden ratio in minutes to a number of nanoseconds.
         This is the same as about 97082039324.994 nanoseconds, so it should round up
         to 97082039325. *)
      print_nanos "1.6180339887498949m";
      [%expect {| 97082039325ns |}];

      (* Test the bounds of the rounding behavior for the float parsing - it should
         round to the nearest nanosecond, breaking ties by rounding towards +infinity. *)
      print_nanos "0.1231231234s";
      print_nanos "0.123123123499s";
      print_nanos "0.1231231235s";
      print_nanos "0.1231231236s";
      [%expect {|
        123123123ns
        123123123ns
        123123124ns
        123123124ns |}];
      print_nanos "-0.1231231234s";
      print_nanos "-0.123123123499s";
      print_nanos "-0.1231231235s";
      print_nanos "-0.1231231236s";
      [%expect {|
        -123123123ns
        -123123123ns
        -123123123ns
        -123123124ns |}];

      (* 0.3333333333333...m and 0.33333333335m are 1 ns apart.
         The midpoint point between them is 0.333333333341666....
         which is the boundary at which we should start getting 20 billion or
         20 billion + 1 nanos. *)
      print_nanos "0.3333333333333333333333333333333334m";
      print_nanos "0.3333333333416666666666666666666666m";
      print_nanos "0.333333333341666666666666666666666659m";
      print_nanos "0.3333333333416666666666666666666667m";
      print_nanos "0.3333333333500000000000000000000000m";
      [%expect {|
        20000000000ns
        20000000000ns
        20000000000ns
        20000000001ns
        20000000001ns |}];
      print_nanos "-0.3333333333333333333333333333333334m";
      print_nanos "-0.3333333333416666666666666666666666m";
      print_nanos "-0.333333333341666666666666666666666659m";
      print_nanos "-0.3333333333416666666666666666666667m";
      print_nanos "-0.3333333333500000000000000000000000m";
      [%expect {|
        -20000000000ns
        -20000000000ns
        -20000000000ns
        -20000000001ns
        -20000000001ns |}];

      (* 0.6666666666666...m and 0.66666666668333...m are 1 ns apart.
         The midpoint point between them is 0.666666666675m.
         which is the boundary at which we should start getting 40 billion or
         40 billion + 1 nanos. *)
      print_nanos "0.666666666674m";
      print_nanos "0.6666666666749m";
      print_nanos "0.666666666675m";
      print_nanos "0.66666666667500000000m";
      print_nanos "0.66666666667500000001m";
      [%expect {|
        40000000000ns
        40000000000ns
        40000000001ns
        40000000001ns
        40000000001ns |}];
      print_nanos "-0.666666666674m";
      print_nanos "-0.6666666666749m";
      print_nanos "-0.666666666675m";
      print_nanos "-0.66666666667500000000m";
      print_nanos "-0.66666666667500000001m";
      [%expect {|
        -40000000000ns
        -40000000000ns
        -40000000000ns
        -40000000000ns
        -40000000001ns |}];
    ;;

    let%expect_test "of_string: weird cases of underscore" =
      let test here str =
        require_does_not_raise here (fun () -> print_nanos str)
      in

      test [%here] "1s1s";
      test [%here] "1s1._s";
      test [%here] "1_s1_.s";

      test [%here] "0.000_123ms123ns123_123us0.000_123_123s";
      test [%here] "1d10_0_0_0_0_0s";

      [%expect {|
        2000000000ns
        2000000000ns
        2000000000ns
        123246369ns
        1086400000000000ns |}]
    ;;

    (* Test a bunch of random floats and make sure span parsing code rounds the same
       way as the float would. *)
    let%expect_test "of_string: random float parsing approx" =
      let rand =
        Random.State.make [| Hashtbl.hash "Time_ns random-float-parsing-approx" |]
      in

      (* When you multiply a float x by an integer n, sometimes the value y := (x*n) will
         not exactly be representable as a float. That means that the computed y will
         actually be a different value than the idealized mathematical (x*n).

         If that difference puts the computed y and the ideal (x*n) on different sides of
         a rounding boundary, we will get a different number of nanoseconds compared to if
         we had parsed x directly with correct rounding. So allow some tolerance on the
         difference in this test.

         The larger that [n] is, the more likely this is, because (unless n is a multiple
         of a large power of 2), the more we run into the fact that floats have a bounded
         number of bits of precision. *)
      let num_equality_tests  = ref 0 in
      let num_equaled_exactly = ref 0 in
      let print_ratio () =
        printf "%d/%d equality tests were exact\n"
          !num_equaled_exactly
          !num_equality_tests;
        num_equaled_exactly := 0;
        num_equality_tests  := 0;
      in
      let approx_equal here span float_ns ~tolerance =
        let open Int63.O in
        let diff_ns =
          Int63.abs
            (Time_ns.Span.to_int63_ns span - Float.int63_round_nearest_exn float_ns)
        in
        incr num_equality_tests;
        require here
          (if diff_ns = zero
           then (incr num_equaled_exactly; true)
           else diff_ns <= Int63.of_int tolerance)
          ~if_false_then_print_s:
            (lazy [%message
              "rounding failed"
                (span      : Time_ns.Span.t)
                (float_ns  : float)
                (diff_ns   : Int63.t)
                (tolerance : int)])
      in

      for _ = 1 to 20000 do
        let float = Random.State.float_range rand (-5.0) 5.0 in
        let float_str = sprintf "%.25f" float in
        let test here ~suffix ~factor ~tolerance =
          let span_str = float_str ^ suffix in
          approx_equal here (Time_ns.Span.of_string span_str) (float *. factor) ~tolerance
        in
        test [%here] ~suffix:"ns" ~factor:             1. ~tolerance:0;
        test [%here] ~suffix:"us" ~factor:         1_000. ~tolerance:1;
        test [%here] ~suffix:"ms" ~factor:     1_000_000. ~tolerance:1;
        test [%here] ~suffix:"s"  ~factor: 1_000_000_000. ~tolerance:1;
        test [%here] ~suffix:"m"  ~factor:60_000_000_000. ~tolerance:1;
      done;
      (* The fraction of exact equalities should be *almost exactly* 1. The exact fraction
         might change if [Random.State] ever changes in a future OCaml version, that's
         okay. *)
      print_ratio ();
      [%expect {| 100000/100000 equality tests were exact |}];

      for _ = 1 to 20000 do
        let float = Random.State.float_range rand (-5.0) 5.0 in
        let float_str = sprintf "%.25f" float in

        let span_str = float_str ^ "h" in
        approx_equal [%here]
          (Time_ns.Span.of_string span_str)
          (float *. 3_600_000_000_000.)
          ~tolerance:1;
      done;
      (* The fraction of exact equalities should be *very close* to 1.
         The exact fraction might change if [Random.State] ever changes in a future ocaml
         version, that's okay. *)
      print_ratio ();
      [%expect {| 19987/20000 equality tests were exact |}];

      for _ = 1 to 20000 do
        let float = Random.State.float_range rand (-5.0) 5.0 in
        let float_str = sprintf "%.25f" float in

        let span_str = float_str ^ "d" in
        approx_equal [%here]
          (Time_ns.Span.of_string span_str)
          (float *. 86_400_000_000_000.)
          ~tolerance:1;
      done;
      (* The fraction of exact equalities should be *reasonably close* to 1.
         The exact fraction might change if [Random.State] ever changes in a future ocaml
         version, that's okay. *)
      print_ratio ();
      [%expect {| 19652/20000 equality tests were exact |}];
    ;;

    (* Test a bunch of random floats, but this time specifically generated to be on
       half-nanosecond-boundaries a large fraction of time, and therefore trigger
       "ties" a lot, to test the exact rounding behavior. *)
    let%test_unit "random-float-parsing-exact" =
      let rand =
        Random.State.make [| Hashtbl.hash "Time_ns random-float-parsing-exact" |]
      in
      let min = -8_000_000_000L |> Int63.of_int64_exn in
      let max =  8_000_000_000L |> Int63.of_int64_exn in
      for _ = 1 to 10000 do
        let int63 = Int63.random_incl ~state:rand min max in
        let float = Int63.to_float int63 in

        (* Divide by 4_000_000_000 so that we end up exactly on quarter-nanosecond values,
           so that we test exact half-nanosecond rounding behavior a lot, as well as the
           behavior in the intervals in between. *)
        let seconds_divisor = 4_000_000_000. in
        let ns_divisor = 4. in

        let span_str = sprintf "%.11fs" (float /. seconds_divisor) in

        (* Rounds ties towards positive infinity manually via integer math *)
        let expected_ns_via_int_math =
          let open Int63 in
          if int63 >= zero
          then (int63 + of_int 2) / of_int 4
          else (int63 - of_int 1) / of_int 4
        in

        (* Float also rounds ties towards positive infinity *)
        let expected_ns_via_float_math =
          Float.int63_round_nearest_exn (float /. ns_divisor)
        in

        [%test_result: Int63.t]
          (Time_ns.Span.to_int63_ns (Time_ns.Span.of_string span_str))
          ~expect:expected_ns_via_int_math;
        [%test_result: Int63.t]
          (Time_ns.Span.to_int63_ns (Time_ns.Span.of_string span_str))
          ~expect:expected_ns_via_float_math;
      done
    ;;

    let%expect_test "way too big should overflow" =
      let test str =
        require_does_raise [%here] (fun () ->
          print_nanos str)
      in

      (* These should all definitely overflow *)
      test "123456789012345678901234567890.1234567890ns";
      test "-123456789012345678901234567890.1234567890ns";
      test "123456789012345678901234567890.1234567890us";
      test "-123456789012345678901234567890.1234567890us";
      test "123456789012345678901234567890.1234567890ms";
      test "-123456789012345678901234567890.1234567890ms";
      test "123456789012345678901234567890.1234567890s";
      test "-123456789012345678901234567890.1234567890s";
      test "123456789012345678901234567890.1234567890m";
      test "-123456789012345678901234567890.1234567890m";
      test "123456789012345678901234567890.1234567890h";
      test "-123456789012345678901234567890.1234567890h";
      test "123456789012345678901234567890.1234567890d";
      test "-123456789012345678901234567890.1234567890d";
      [%expect {|
        ("Time_ns.Span.of_string: invalid string"
          (string 123456789012345678901234567890.1234567890ns)
          (reason "span would be outside of int63 range"))
        ("Time_ns.Span.of_string: invalid string"
          (string -123456789012345678901234567890.1234567890ns)
          (reason "span would be outside of int63 range"))
        ("Time_ns.Span.of_string: invalid string"
          (string 123456789012345678901234567890.1234567890us)
          (reason "span would be outside of int63 range"))
        ("Time_ns.Span.of_string: invalid string"
          (string -123456789012345678901234567890.1234567890us)
          (reason "span would be outside of int63 range"))
        ("Time_ns.Span.of_string: invalid string"
          (string 123456789012345678901234567890.1234567890ms)
          (reason "span would be outside of int63 range"))
        ("Time_ns.Span.of_string: invalid string"
          (string -123456789012345678901234567890.1234567890ms)
          (reason "span would be outside of int63 range"))
        ("Time_ns.Span.of_string: invalid string"
          (string 123456789012345678901234567890.1234567890s)
          (reason "span would be outside of int63 range"))
        ("Time_ns.Span.of_string: invalid string"
          (string -123456789012345678901234567890.1234567890s)
          (reason "span would be outside of int63 range"))
        ("Time_ns.Span.of_string: invalid string"
          (string 123456789012345678901234567890.1234567890m)
          (reason "span would be outside of int63 range"))
        ("Time_ns.Span.of_string: invalid string"
          (string -123456789012345678901234567890.1234567890m)
          (reason "span would be outside of int63 range"))
        ("Time_ns.Span.of_string: invalid string"
          (string 123456789012345678901234567890.1234567890h)
          (reason "span would be outside of int63 range"))
        ("Time_ns.Span.of_string: invalid string"
          (string -123456789012345678901234567890.1234567890h)
          (reason "span would be outside of int63 range"))
        ("Time_ns.Span.of_string: invalid string"
          (string 123456789012345678901234567890.1234567890d)
          (reason "span would be outside of int63 range"))
        ("Time_ns.Span.of_string: invalid string"
          (string -123456789012345678901234567890.1234567890d)
          (reason "span would be outside of int63 range")) |}]
    ;;

    let%expect_test "precise overflow boundary testing" =
      (* Use Bigint to do some fixed-point computations with precision well exceeding that
         of an Int63 to compute things like the decimal number of hours needed to overflow
         or underflow an Int63 number of nanoseconds. *)
      let open Bigint.O in

      let max = Bigint.of_int64 (Int63.to_int64 (Int63.max_value)) in
      let min = Bigint.of_int64 (Int63.to_int64 (Int63.min_value)) in
      let max_next = max + Bigint.one in
      let min_next = min - Bigint.one in

      let max_x100 = max * Bigint.of_int 100 in
      let min_x100 = min * Bigint.of_int 100 in
      let max_wont_round_x100 = max_x100 + Bigint.of_int 49 in
      let min_wont_round_x100 = min_x100 - Bigint.of_int 50 in
      let max_will_round_x100 = max_x100 + Bigint.of_int 50 in
      let min_will_round_x100 = min_x100 - Bigint.of_int 51 in
      let max_next_x100 = max_x100 + Bigint.of_int 100 in
      let min_next_x100 = min_x100 - Bigint.of_int 100 in

      let test ?decimals bignum suffix =
        let string =
          let bigstr = Bigint.to_string bignum in
          let prefix =
            match decimals with
            | None   -> bigstr
            | Some n -> String.drop_suffix bigstr n ^ "." ^ String.suffix bigstr n
          in
          prefix ^ suffix
        in
        print_endline "";
        print_endline string;
        show_raise (fun () ->
          print_nanos string)
      in

      (* Nanosecond overflow boundary ----------------------------------------- *)
      test max                             "ns";
      test max_wont_round_x100 ~decimals:2 "ns";
      test max_will_round_x100 ~decimals:2 "ns";
      test max_next                        "ns";
      [%expect {|
        4611686018427387903ns
        4611686018427387903ns
        "did not raise"

        4611686018427387903.49ns
        4611686018427387903ns
        "did not raise"

        4611686018427387903.50ns
        (raised (
          "Time_ns.Span.of_string: invalid string"
          (string 4611686018427387903.50ns)
          (reason "span would be outside of int63 range")))

        4611686018427387904ns
        (raised (
          "Time_ns.Span.of_string: invalid string"
          (string 4611686018427387904ns)
          (reason "span would be outside of int63 range"))) |}];

      test min                             "ns";
      test min_wont_round_x100 ~decimals:2 "ns";
      test min_will_round_x100 ~decimals:2 "ns";
      test min_next                        "ns";
      [%expect {|
        -4611686018427387904ns
        -4611686018427387904ns
        "did not raise"

        -4611686018427387904.50ns
        -4611686018427387904ns
        "did not raise"

        -4611686018427387904.51ns
        (raised (
          "Time_ns.Span.of_string: invalid string"
          (string -4611686018427387904.51ns)
          (reason "span would be outside of int63 range")))

        -4611686018427387905ns
        (raised (
          "Time_ns.Span.of_string: invalid string"
          (string -4611686018427387905ns)
          (reason "span would be outside of int63 range"))) |}];

      (* Microsecond overflow boundary ----------------------------------------- *)
      test max_x100            ~decimals:5 "us";
      test max_wont_round_x100 ~decimals:5 "us";
      test max_will_round_x100 ~decimals:5 "us";
      test max_next_x100       ~decimals:5 "us";
      [%expect {|
        4611686018427387.90300us
        4611686018427387903ns
        "did not raise"

        4611686018427387.90349us
        4611686018427387903ns
        "did not raise"

        4611686018427387.90350us
        (raised (
          "Time_ns.Span.of_string: invalid string"
          (string 4611686018427387.90350us)
          (reason "span would be outside of int63 range")))

        4611686018427387.90400us
        (raised (
          "Time_ns.Span.of_string: invalid string"
          (string 4611686018427387.90400us)
          (reason "span would be outside of int63 range"))) |}];

      test min_x100            ~decimals:5 "us";
      test min_wont_round_x100 ~decimals:5 "us";
      test min_will_round_x100 ~decimals:5 "us";
      test min_next_x100       ~decimals:5 "us";
      [%expect {|
        -4611686018427387.90400us
        -4611686018427387904ns
        "did not raise"

        -4611686018427387.90450us
        -4611686018427387904ns
        "did not raise"

        -4611686018427387.90451us
        (raised (
          "Time_ns.Span.of_string: invalid string"
          (string -4611686018427387.90451us)
          (reason "span would be outside of int63 range")))

        -4611686018427387.90500us
        (raised (
          "Time_ns.Span.of_string: invalid string"
          (string -4611686018427387.90500us)
          (reason "span would be outside of int63 range"))) |}];

      (* Millisecond overflow boundary ----------------------------------------- *)
      test max_x100            ~decimals:8 "ms";
      test max_wont_round_x100 ~decimals:8 "ms";
      test max_will_round_x100 ~decimals:8 "ms";
      test max_next_x100       ~decimals:8 "ms";
      [%expect {|
        4611686018427.38790300ms
        4611686018427387903ns
        "did not raise"

        4611686018427.38790349ms
        4611686018427387903ns
        "did not raise"

        4611686018427.38790350ms
        (raised (
          "Time_ns.Span.of_string: invalid string"
          (string 4611686018427.38790350ms)
          (reason "span would be outside of int63 range")))

        4611686018427.38790400ms
        (raised (
          "Time_ns.Span.of_string: invalid string"
          (string 4611686018427.38790400ms)
          (reason "span would be outside of int63 range"))) |}];

      test min_x100            ~decimals:8 "ms";
      test min_wont_round_x100 ~decimals:8 "ms";
      test min_will_round_x100 ~decimals:8 "ms";
      test min_next_x100       ~decimals:8 "ms";
      [%expect {|
        -4611686018427.38790400ms
        -4611686018427387904ns
        "did not raise"

        -4611686018427.38790450ms
        -4611686018427387904ns
        "did not raise"

        -4611686018427.38790451ms
        (raised (
          "Time_ns.Span.of_string: invalid string"
          (string -4611686018427.38790451ms)
          (reason "span would be outside of int63 range")))

        -4611686018427.38790500ms
        (raised (
          "Time_ns.Span.of_string: invalid string"
          (string -4611686018427.38790500ms)
          (reason "span would be outside of int63 range"))) |}];

      (* Second overflow boundary ----------------------------------------- *)
      test max_x100            ~decimals:11 "s";
      test max_wont_round_x100 ~decimals:11 "s";
      test max_will_round_x100 ~decimals:11 "s";
      test max_next_x100       ~decimals:11 "s";
      [%expect {|
        4611686018.42738790300s
        4611686018427387903ns
        "did not raise"

        4611686018.42738790349s
        4611686018427387903ns
        "did not raise"

        4611686018.42738790350s
        (raised (
          "Time_ns.Span.of_string: invalid string"
          (string 4611686018.42738790350s)
          (reason "span would be outside of int63 range")))

        4611686018.42738790400s
        (raised (
          "Time_ns.Span.of_string: invalid string"
          (string 4611686018.42738790400s)
          (reason "span would be outside of int63 range"))) |}];

      test min_x100            ~decimals:11 "s";
      test min_wont_round_x100 ~decimals:11 "s";
      test min_will_round_x100 ~decimals:11 "s";
      test min_next_x100       ~decimals:11 "s";
      [%expect {|
        -4611686018.42738790400s
        -4611686018427387904ns
        "did not raise"

        -4611686018.42738790450s
        -4611686018427387904ns
        "did not raise"

        -4611686018.42738790451s
        (raised (
          "Time_ns.Span.of_string: invalid string"
          (string -4611686018.42738790451s)
          (reason "span would be outside of int63 range")))

        -4611686018.42738790500s
        (raised (
          "Time_ns.Span.of_string: invalid string"
          (string -4611686018.42738790500s)
          (reason "span would be outside of int63 range"))) |}];

      (* Minute overflow boundary ----------------------------------------- *)
      (* Round towards zero vs round away from zero *)
      let minuteify_rtz x = (x * Bigint.of_int 100) / Bigint.of_int 60 in
      let minuteify_raz x =
        if x < Bigint.of_int 0
        then ((x * Bigint.of_int 100) - Bigint.of_int 59) / Bigint.of_int 60
        else ((x * Bigint.of_int 100) + Bigint.of_int 59) / Bigint.of_int 60
      in
      test (minuteify_rtz max_x100)            ~decimals:13 "m";
      test (minuteify_rtz max_wont_round_x100) ~decimals:13 "m";
      test (minuteify_raz max_will_round_x100) ~decimals:13 "m";
      test (minuteify_raz max_next_x100)       ~decimals:13 "m";
      [%expect {|
        76861433.6404564650500m
        4611686018427387903ns
        "did not raise"

        76861433.6404564650581m
        4611686018427387903ns
        "did not raise"

        76861433.6404564650584m
        (raised (
          "Time_ns.Span.of_string: invalid string"
          (string 76861433.6404564650584m)
          (reason "span would be outside of int63 range")))

        76861433.6404564650667m
        (raised (
          "Time_ns.Span.of_string: invalid string"
          (string 76861433.6404564650667m)
          (reason "span would be outside of int63 range"))) |}];

      test (minuteify_rtz min_x100)            ~decimals:13 "m";
      test (minuteify_rtz min_wont_round_x100) ~decimals:13 "m";
      test (minuteify_raz min_will_round_x100) ~decimals:13 "m";
      test (minuteify_raz min_next_x100)       ~decimals:13 "m";
      [%expect {|
        -76861433.6404564650666m
        -4611686018427387904ns
        "did not raise"

        -76861433.6404564650750m
        -4611686018427387904ns
        "did not raise"

        -76861433.6404564650752m
        (raised (
          "Time_ns.Span.of_string: invalid string"
          (string -76861433.6404564650752m)
          (reason "span would be outside of int63 range")))

        -76861433.6404564650834m
        (raised (
          "Time_ns.Span.of_string: invalid string"
          (string -76861433.6404564650834m)
          (reason "span would be outside of int63 range"))) |}];

      (* Hour overflow boundary ----------------------------------------- *)
      (* Round towards zero vs round away from zero *)
      let hourify_rtz x = x * Bigint.of_int 10000 / Bigint.of_int 3600 in
      let hourify_raz x =
        if x < Bigint.of_int 0
        then (x * Bigint.of_int 10000 - Bigint.of_int 3599) / Bigint.of_int 3600
        else (x * Bigint.of_int 10000 + Bigint.of_int 3599) / Bigint.of_int 3600
      in
      test (hourify_rtz max_x100)            ~decimals:15 "h";
      test (hourify_rtz max_wont_round_x100) ~decimals:15 "h";
      test (hourify_raz max_will_round_x100) ~decimals:15 "h";
      test (hourify_raz max_next_x100)       ~decimals:15 "h";
      [%expect {|
        1281023.894007607750833h
        4611686018427387903ns
        "did not raise"

        1281023.894007607750969h
        4611686018427387903ns
        "did not raise"

        1281023.894007607750973h
        (raised (
          "Time_ns.Span.of_string: invalid string"
          (string 1281023.894007607750973h)
          (reason "span would be outside of int63 range")))

        1281023.894007607751112h
        (raised (
          "Time_ns.Span.of_string: invalid string"
          (string 1281023.894007607751112h)
          (reason "span would be outside of int63 range"))) |}];

      test (hourify_rtz min_x100)            ~decimals:15 "h";
      test (hourify_rtz min_wont_round_x100) ~decimals:15 "h";
      test (hourify_raz min_will_round_x100) ~decimals:15 "h";
      test (hourify_raz min_next_x100)       ~decimals:15 "h";
      [%expect {|
        -1281023.894007607751111h
        -4611686018427387904ns
        "did not raise"

        -1281023.894007607751250h
        -4611686018427387904ns
        "did not raise"

        -1281023.894007607751253h
        (raised (
          "Time_ns.Span.of_string: invalid string"
          (string -1281023.894007607751253h)
          (reason "span would be outside of int63 range")))

        -1281023.894007607751389h
        (raised (
          "Time_ns.Span.of_string: invalid string"
          (string -1281023.894007607751389h)
          (reason "span would be outside of int63 range"))) |}];

      (* Day overflow boundary ----------------------------------------- *)
      (* Round towards zero vs round away from zero *)
      let dayify_rtz x = x * Bigint.of_int 1000000 / Bigint.of_int 86400 in
      let dayify_raz x =
        if x < Bigint.of_int 0
        then (x * Bigint.of_int 1000000 - Bigint.of_int 86399) / Bigint.of_int 86400
        else (x * Bigint.of_int 1000000 + Bigint.of_int 86399) / Bigint.of_int 86400
      in
      test (dayify_rtz max_x100)            ~decimals:17 "d";
      test (dayify_rtz max_wont_round_x100) ~decimals:17 "d";
      test (dayify_raz max_will_round_x100) ~decimals:17 "d";
      test (dayify_raz max_next_x100)       ~decimals:17 "d";
      [%expect {|
        53375.99558365032295138d
        4611686018427387903ns
        "did not raise"

        53375.99558365032295706d
        4611686018427387903ns
        "did not raise"

        53375.99558365032295718d
        (raised (
          "Time_ns.Span.of_string: invalid string"
          (string 53375.99558365032295718d)
          (reason "span would be outside of int63 range")))

        53375.99558365032296297d
        (raised (
          "Time_ns.Span.of_string: invalid string"
          (string 53375.99558365032296297d)
          (reason "span would be outside of int63 range"))) |}];

      test (dayify_rtz min_x100)            ~decimals:17 "d";
      test (dayify_rtz min_wont_round_x100) ~decimals:17 "d";
      test (dayify_raz min_will_round_x100) ~decimals:17 "d";
      test (dayify_raz min_next_x100)       ~decimals:17 "d";
      [%expect {|
        -53375.99558365032296296d
        -4611686018427387904ns
        "did not raise"

        -53375.99558365032296875d
        -4611686018427387904ns
        "did not raise"

        -53375.99558365032296887d
        (raised (
          "Time_ns.Span.of_string: invalid string"
          (string -53375.99558365032296887d)
          (reason "span would be outside of int63 range")))

        -53375.99558365032297454d
        (raised (
          "Time_ns.Span.of_string: invalid string"
          (string -53375.99558365032297454d)
          (reason "span would be outside of int63 range"))) |}];
    ;;

    let%expect_test "additional-overflow-testing" =
      let test str =
        show_raise (fun () ->
          print_nanos str)
      in

      (* Should not overflow. *)
      test "53375d";
      test "-53375d";
      [%expect {|
        4611600000000000000ns
        "did not raise"
        -4611600000000000000ns
        "did not raise" |}];

      (* Should be overflow directly on the integer part *)
      test "53376d";
      test "-53376d";
      [%expect {|
        (raised (
          "Time_ns.Span.of_string: invalid string"
          (string 53376d)
          (reason "span would be outside of int63 range")))
        (raised (
          "Time_ns.Span.of_string: invalid string"
          (string -53376d)
          (reason "span would be outside of int63 range"))) |}];

      (* Should be overflow directly on the integer part, upon the multiply by ten rather
         than upon adding the digit. *)
      test "53380d";
      test "-53380d";
      [%expect {|
        (raised (
          "Time_ns.Span.of_string: invalid string"
          (string 53380d)
          (reason "span would be outside of int63 range")))
        (raised (
          "Time_ns.Span.of_string: invalid string"
          (string -53380d)
          (reason "span would be outside of int63 range"))) |}];

      (* Should be overflow upon adding the fractional part but not the integer part *)
      test "53375.999d";
      test "-53375.999d";
      [%expect {|
        (raised (
          "Time_ns.Span.of_string: invalid string"
          (string 53375.999d)
          (reason "span would be outside of int63 range")))
        (raised (
          "Time_ns.Span.of_string: invalid string"
          (string -53375.999d)
          (reason "span would be outside of int63 range"))) |}];

      (* Should be overflow on combining parts but not on individual parts *)
      test "30000d30000d";
      test "50000000m3000000000000000000ns";
      [%expect {|
        (raised (
          "Time_ns.Span.of_string: invalid string"
          (string 30000d30000d)
          (reason "span would be outside of int63 range")))
        (raised (
          "Time_ns.Span.of_string: invalid string"
          (string 50000000m3000000000000000000ns)
          (reason "span would be outside of int63 range"))) |}];
    ;;
  end)
;;

let%expect_test "Time_ns.Span.Stable.V1" =
  let module V = Time_ns.Span.Stable.V1 in
  let make int64 = V.of_int63_exn (Int63.of_int64_exn int64) in
  (* stable checks for values that round-trip *)
  print_and_check_stable_int63able_type [%here] (module V) [
    make                      0L;
    make                  1_000L;
    make          1_000_000_000L;
    make      1_234_560_000_000L;
    make 71_623_008_000_000_000L;
    make 80_000_006_400_000_000L;
  ];
  [%expect {|
    (bin_shape_digest 2b528f4b22f08e28876ffe0239315ac2)
    ((sexp   0s)
     (bin_io "\000")
     (int63  0))
    ((sexp   0.001ms)
     (bin_io "\254\232\003")
     (int63  1000))
    ((sexp   1s)
     (bin_io "\253\000\202\154;")
     (int63  1000000000))
    ((sexp   20.576m)
     (bin_io "\252\000\160\130q\031\001\000\000")
     (int63  1234560000000))
    ((sexp   828.97d)
     (bin_io "\252\000\192\149\r\191t\254\000")
     (int63  71623008000000000))
    ((sexp   925.926d)
     (bin_io "\252\000@\128\251\1487\028\001")
     (int63  80000006400000000)) |}];
  (* stable checks for values that do not precisely round-trip *)
  print_and_check_stable_int63able_type [%here] (module V) ~cr:Comment [
    make              1L;
    make 11_275_440_000L;
  ];
  [%expect {|
    (bin_shape_digest 2b528f4b22f08e28876ffe0239315ac2)
    ((sexp   0s)
     (bin_io "\001")
     (int63  1))
    (* require-failed: lib/core/test/src/test_time_ns.ml:LINE:COL. *)
    ("sexp serialization failed to round-trip"
      (original       0s)
      (sexp           0s)
      (sexp_roundtrip 0s))
    ((sexp   11.2754s)
     (bin_io "\252\128\143\017\160\002\000\000\000")
     (int63  11275440000))
    (* require-failed: lib/core/test/src/test_time_ns.ml:LINE:COL. *)
    ("sexp serialization failed to round-trip"
      (original       11.2754s)
      (sexp           11.2754s)
      (sexp_roundtrip 11.2754s)) |}];
  (* make sure [of_int63_exn] checks range *)
  show_raise ~hide_positions:true (fun () ->
    V.of_int63_exn (Int63.succ Int63.min_value));
  [%expect {|
    (raised (
      "Span.t exceeds limits"
      (t         -53375d23h53m38.427387903s)
      (min_value -49275d)
      (max_value 49275d))) |}];
;;

let%test_module "Time_ns.Span.Stable.V2" =
  (module struct
    module V = Time_ns.Span.Stable.V2

    let%test_unit "round-trip" =
      Quickcheck.test ~examples:span_examples span_gen ~f:(fun span ->
        let rt = V.t_of_sexp (V.sexp_of_t span) in
        [%test_eq: Time_ns.Span.t] span rt;
        let rt = V.of_int63_exn (V.to_int63 span) in
        [%test_eq: Time_ns.Span.t] span rt;)
    ;;

    let%expect_test "stability" =
      let make int64 = V.of_int63_exn (Int63.of_int64_exn int64) in
      print_and_check_stable_int63able_type [%here] (module V) [
        make                           0L;
        make                           1L;
        make                       (-499L);
        make                         500L;
        make                     (-1_000L);
        make                 987_654_321L;
        make           (-123_456_789_012L);
        make          52_200_010_101_101L;
        make        (-86_399_999_999_999L);
        make          86_400_000_000_000L;
        make     (-1_000_000_222_000_333L);
        make      80_000_006_400_000_000L;
        make (-1_381_156_200_010_101_000L);
        make   4_110_307_199_999_999_000L;
        make (Int63.to_int64 Int63.max_value);
        make (Int63.to_int64 Int63.min_value);
      ];
      [%expect {|
        (bin_shape_digest 2b528f4b22f08e28876ffe0239315ac2)
        ((sexp   0s)
         (bin_io "\000")
         (int63  0))
        ((sexp   1ns)
         (bin_io "\001")
         (int63  1))
        ((sexp   -499ns)
         (bin_io "\254\r\254")
         (int63  -499))
        ((sexp   500ns)
         (bin_io "\254\244\001")
         (int63  500))
        ((sexp   -1us)
         (bin_io "\254\024\252")
         (int63  -1000))
        ((sexp   987.654321ms)
         (bin_io "\253\177h\222:")
         (int63  987654321))
        ((sexp   -2m3.456789012s)
         (bin_io "\252\236\229fA\227\255\255\255")
         (int63  -123456789012))
        ((sexp   14h30m10.101101ms)
         (bin_io "\252m1\015\195y/\000\000")
         (int63  52200010101101))
        ((sexp   -23h59m59.999999999s)
         (bin_io "\252\001\000\177nk\177\255\255")
         (int63  -86399999999999))
        ((sexp   1d)
         (bin_io "\252\000\000O\145\148N\000\000")
         (int63  86400000000000))
        ((sexp   -11d13h46m40.222000333s)
         (bin_io "\2523\011\254M\129r\252\255")
         (int63  -1000000222000333))
        ((sexp   925d22h13m26.4s)
         (bin_io "\252\000@\128\251\1487\028\001")
         (int63  80000006400000000))
        ((sexp   -15985d14h30m10.101ms)
         (bin_io "\252\248\206\017\247\192%\213\236")
         (int63  -1381156200010101000))
        ((sexp   47572d23h59m59.999999s)
         (bin_io "\252\024\252\186\253\158\190\n9")
         (int63  4110307199999999000))
        ((sexp   53375d23h53m38.427387903s)
         (bin_io "\252\255\255\255\255\255\255\255?")
         (int63  4611686018427387903))
        ((sexp   -53375d23h53m38.427387904s)
         (bin_io "\252\000\000\000\000\000\000\000\192")
         (int63  -4611686018427387904)) |}];
    ;;
  end)
;;

let%test_module "Time_ns.Span.Option.Stable.V2" =
  (module struct
    module V = Time_ns.Span.Option.Stable.V2

    let%test_unit "round-trip" =
      Quickcheck.test
        ~examples:span_option_examples
        span_option_gen
        ~f:(fun span ->
          let rt = V.t_of_sexp (V.sexp_of_t span) in
          [%test_eq: Time_ns.Span.Option.t] span rt;
          let rt = V.of_int63_exn (V.to_int63 span) in
          [%test_eq: Time_ns.Span.Option.t] span rt;
        )
    ;;

    let%expect_test "stability" =
      let make int64 = V.of_int63_exn (Int63.of_int64_exn int64) in
      print_and_check_stable_int63able_type [%here] (module V) [
        make                           0L;
        make                           1L;
        make                       (-499L);
        make                         500L;
        make                     (-1_000L);
        make                 987_654_321L;
        make           (-123_456_789_012L);
        make          52_200_010_101_101L;
        make        (-86_399_999_999_999L);
        make          86_400_000_000_000L;
        make     (-1_000_000_222_000_333L);
        make      80_000_006_400_000_000L;
        make (-1_381_156_200_010_101_000L);
        make   4_110_307_199_999_999_000L;
        make (Int63.to_int64 Int63.max_value);
        make (Int63.to_int64 Int63.min_value); (* none *)
      ];
      [%expect {|
        (bin_shape_digest 2b528f4b22f08e28876ffe0239315ac2)
        ((sexp (0s))
         (bin_io "\000")
         (int63  0))
        ((sexp (1ns))
         (bin_io "\001")
         (int63  1))
        ((sexp (-499ns))
         (bin_io "\254\r\254")
         (int63  -499))
        ((sexp (500ns))
         (bin_io "\254\244\001")
         (int63  500))
        ((sexp (-1us))
         (bin_io "\254\024\252")
         (int63  -1000))
        ((sexp (987.654321ms))
         (bin_io "\253\177h\222:")
         (int63  987654321))
        ((sexp (-2m3.456789012s))
         (bin_io "\252\236\229fA\227\255\255\255")
         (int63  -123456789012))
        ((sexp (14h30m10.101101ms))
         (bin_io "\252m1\015\195y/\000\000")
         (int63  52200010101101))
        ((sexp (-23h59m59.999999999s))
         (bin_io "\252\001\000\177nk\177\255\255")
         (int63  -86399999999999))
        ((sexp (1d))
         (bin_io "\252\000\000O\145\148N\000\000")
         (int63  86400000000000))
        ((sexp (-11d13h46m40.222000333s))
         (bin_io "\2523\011\254M\129r\252\255")
         (int63  -1000000222000333))
        ((sexp (925d22h13m26.4s))
         (bin_io "\252\000@\128\251\1487\028\001")
         (int63  80000006400000000))
        ((sexp (-15985d14h30m10.101ms))
         (bin_io "\252\248\206\017\247\192%\213\236")
         (int63  -1381156200010101000))
        ((sexp (47572d23h59m59.999999s))
         (bin_io "\252\024\252\186\253\158\190\n9")
         (int63  4110307199999999000))
        ((sexp (53375d23h53m38.427387903s))
         (bin_io "\252\255\255\255\255\255\255\255?")
         (int63  4611686018427387903))
        ((sexp ())
         (bin_io "\252\000\000\000\000\000\000\000\192")
         (int63  -4611686018427387904)) |}];
    ;;
  end)
;;

let%expect_test "Time_ns.Span.Option.Stable.V1" =
  let module V = Time_ns.Span.Option.Stable.V1 in
  let make int64 = V.of_int63_exn (Int63.of_int64_exn int64) in
  (* stable checks for values that round-trip *)
  print_and_check_stable_int63able_type [%here] (module V) [
    make                           0L;
    make                       1_000L;
    make               1_000_000_000L;
    make           1_234_560_000_000L;
    make      71_623_008_000_000_000L;
    make      80_000_006_400_000_000L;
    make (-4_611_686_018_427_387_904L);
  ] ~hide_positions:true;
  [%expect {|
    (bin_shape_digest 2b528f4b22f08e28876ffe0239315ac2)
    ((sexp (0s))
     (bin_io "\000")
     (int63  0))
    ((sexp (0.001ms))
     (bin_io "\254\232\003")
     (int63  1000))
    ((sexp (1s))
     (bin_io "\253\000\202\154;")
     (int63  1000000000))
    ((sexp (20.576m))
     (bin_io "\252\000\160\130q\031\001\000\000")
     (int63  1234560000000))
    ((sexp (828.97d))
     (bin_io "\252\000\192\149\r\191t\254\000")
     (int63  71623008000000000))
    ((sexp (925.926d))
     (bin_io "\252\000@\128\251\1487\028\001")
     (int63  80000006400000000))
    ((sexp ())
     (bin_io "\252\000\000\000\000\000\000\000\192")
     (int63  -4611686018427387904)) |}];
  (* stable checks for values that do not precisely round-trip *)
  print_and_check_stable_int63able_type [%here] (module V) ~cr:Comment [
    make              1L;
    make 11_275_440_000L;
  ];
  [%expect {|
    (bin_shape_digest 2b528f4b22f08e28876ffe0239315ac2)
    ((sexp (0s))
     (bin_io "\001")
     (int63  1))
    (* require-failed: lib/core/test/src/test_time_ns.ml:LINE:COL. *)
    ("sexp serialization failed to round-trip"
      (original       (0s))
      (sexp           (0s))
      (sexp_roundtrip (0s)))
    ((sexp (11.2754s))
     (bin_io "\252\128\143\017\160\002\000\000\000")
     (int63  11275440000))
    (* require-failed: lib/core/test/src/test_time_ns.ml:LINE:COL. *)
    ("sexp serialization failed to round-trip"
      (original       (11.2754s))
      (sexp           (11.2754s))
      (sexp_roundtrip (11.2754s))) |}];
  (* make sure [of_int63_exn] checks range *)
  show_raise ~hide_positions:true (fun () ->
    V.of_int63_exn (Int63.succ Int63.min_value));
  [%expect {|
    (raised (
      "Span.t exceeds limits"
      (t         -53375d23h53m38.427387903s)
      (min_value -49275d)
      (max_value 49275d))) |}];
;;

let%expect_test "Time_ns.Stable.V1" =
  let module V = Time_ns.Stable.V1 in
  let make int64 = V.of_int63_exn (Int63.of_int64_exn int64) in
  (* stable checks for values that round-trip *)
  print_and_check_stable_int63able_type [%here] (module V) [
    make                         0L;
    make                     1_000L;
    make         1_234_560_000_000L;
    make    80_000_006_400_000_000L;
    make 1_381_156_200_010_101_000L;
    make 4_110_307_199_999_999_000L;
  ];
  [%expect {|
    (bin_shape_digest 2b528f4b22f08e28876ffe0239315ac2)
    ((sexp (1969-12-31 19:00:00.000000-05:00))
     (bin_io "\000")
     (int63  0))
    ((sexp (1969-12-31 19:00:00.000001-05:00))
     (bin_io "\254\232\003")
     (int63  1000))
    ((sexp (1969-12-31 19:20:34.560000-05:00))
     (bin_io "\252\000\160\130q\031\001\000\000")
     (int63  1234560000000))
    ((sexp (1972-07-14 18:13:26.400000-04:00))
     (bin_io "\252\000@\128\251\1487\028\001")
     (int63  80000006400000000))
    ((sexp (2013-10-07 10:30:00.010101-04:00))
     (bin_io "\252\b1\238\b?\218*\019")
     (int63  1381156200010101000))
    ((sexp (2100-04-01 18:59:59.999999-05:00))
     (bin_io "\252\024\252\186\253\158\190\n9")
     (int63  4110307199999999000)) |}];
  (* stable checks for values that do not precisely round-trip *)
  print_and_check_stable_int63able_type [%here] (module V) ~cr:Comment [
    make 1L;
  ];
  [%expect {|
    (bin_shape_digest 2b528f4b22f08e28876ffe0239315ac2)
    ((sexp (1969-12-31 19:00:00.000000-05:00))
     (bin_io "\001")
     (int63  1))
    (* require-failed: lib/core/test/src/test_time_ns.ml:LINE:COL. *)
    ("sexp serialization failed to round-trip"
      (original       (1969-12-31 19:00:00.000000-05:00))
      (sexp           (1969-12-31 19:00:00.000000-05:00))
      (sexp_roundtrip (1969-12-31 19:00:00.000000-05:00))) |}];
  (* make sure [of_int63_exn] checks range *)
  show_raise ~hide_positions:true (fun () ->
    V.of_int63_exn (Int63.succ Int63.min_value));
  [%expect {|
    (raised (
      "Span.t exceeds limits"
      (t         -53375d23h53m38.427387903s)
      (min_value -49275d)
      (max_value 49275d))) |}];
;;

let%expect_test "Time_ns.Option.Stable.V1" =
  let module V = Time_ns.Option.Stable.V1 in
  let make int64 = V.of_int63_exn (Int63.of_int64_exn int64) in
  (* stable checks for values that round-trip *)
  print_and_check_stable_int63able_type [%here] (module V) [
    make                           0L;
    make                       1_000L;
    make           1_234_560_000_000L;
    make      80_000_006_400_000_000L;
    make   1_381_156_200_010_101_000L;
    make   4_110_307_199_999_999_000L;
    make (-4_611_686_018_427_387_904L);
  ];
  [%expect {|
    (bin_shape_digest 2b528f4b22f08e28876ffe0239315ac2)
    ((sexp ((1969-12-31 19:00:00.000000-05:00)))
     (bin_io "\000")
     (int63  0))
    ((sexp ((1969-12-31 19:00:00.000001-05:00)))
     (bin_io "\254\232\003")
     (int63  1000))
    ((sexp ((1969-12-31 19:20:34.560000-05:00)))
     (bin_io "\252\000\160\130q\031\001\000\000")
     (int63  1234560000000))
    ((sexp ((1972-07-14 18:13:26.400000-04:00)))
     (bin_io "\252\000@\128\251\1487\028\001")
     (int63  80000006400000000))
    ((sexp ((2013-10-07 10:30:00.010101-04:00)))
     (bin_io "\252\b1\238\b?\218*\019")
     (int63  1381156200010101000))
    ((sexp ((2100-04-01 18:59:59.999999-05:00)))
     (bin_io "\252\024\252\186\253\158\190\n9")
     (int63  4110307199999999000))
    ((sexp ())
     (bin_io "\252\000\000\000\000\000\000\000\192")
     (int63  -4611686018427387904)) |} ];
  (* stable checks for values that do not precisely round-trip *)
  print_and_check_stable_int63able_type [%here] (module V) ~cr:Comment [
    make 1L;
  ];
  [%expect {|
    (bin_shape_digest 2b528f4b22f08e28876ffe0239315ac2)
    ((sexp ((1969-12-31 19:00:00.000000-05:00)))
     (bin_io "\001")
     (int63  1))
    (* require-failed: lib/core/test/src/test_time_ns.ml:LINE:COL. *)
    ("sexp serialization failed to round-trip"
      (original       ((1969-12-31 19:00:00.000000-05:00)))
      (sexp           ((1969-12-31 19:00:00.000000-05:00)))
      (sexp_roundtrip ((1969-12-31 19:00:00.000000-05:00)))) |}];
  (* make sure [of_int63_exn] checks range *)
  show_raise ~hide_positions:true (fun () ->
    V.of_int63_exn (Int63.succ Int63.min_value));
  [%expect {|
    (raised (
      "Span.t exceeds limits"
      (t         -53375d23h53m38.427387903s)
      (min_value -49275d)
      (max_value 49275d))) |}];
;;

let%test_module "Time_ns.Stable.Ofday.V1" =
  (module struct
    module V = Time_ns.Stable.Ofday.V1

    let%expect_test "stable conversions" =
      let make int64 = V.of_int63_exn (Int63.of_int64_exn int64) in
      (* stable checks for key values *)
      print_and_check_stable_int63able_type [%here] (module V) [
        make                  0L;
        make                  1L;
        make                499L;
        make                500L;
        make              1_000L;
        make    123_456_789_012L;
        make    987_654_321_000L;
        make  1_234_560_000_000L;
        make 52_200_010_101_000L;
        make 86_399_999_999_000L;
        make 86_399_999_999_999L;
        make 86_400_000_000_000L;
      ];
      [%expect {|
        (bin_shape_digest 2b528f4b22f08e28876ffe0239315ac2)
        ((sexp   00:00:00.000000000)
         (bin_io "\000")
         (int63  0))
        ((sexp   00:00:00.000000001)
         (bin_io "\001")
         (int63  1))
        ((sexp   00:00:00.000000499)
         (bin_io "\254\243\001")
         (int63  499))
        ((sexp   00:00:00.000000500)
         (bin_io "\254\244\001")
         (int63  500))
        ((sexp   00:00:00.000001000)
         (bin_io "\254\232\003")
         (int63  1000))
        ((sexp   00:02:03.456789012)
         (bin_io "\252\020\026\153\190\028\000\000\000")
         (int63  123456789012))
        ((sexp   00:16:27.654321000)
         (bin_io "\252h\243\200\244\229\000\000\000")
         (int63  987654321000))
        ((sexp   00:20:34.560000000)
         (bin_io "\252\000\160\130q\031\001\000\000")
         (int63  1234560000000))
        ((sexp   14:30:00.010101000)
         (bin_io "\252\b1\015\195y/\000\000")
         (int63  52200010101000))
        ((sexp   23:59:59.999999000)
         (bin_io "\252\024\252N\145\148N\000\000")
         (int63  86399999999000))
        ((sexp   23:59:59.999999999)
         (bin_io "\252\255\255N\145\148N\000\000")
         (int63  86399999999999))
        ((sexp   24:00:00.000000000)
         (bin_io "\252\000\000O\145\148N\000\000")
         (int63  86400000000000)) |}];
      (* make sure [of_int63_exn] checks range *)
      show_raise ~hide_positions:true (fun () ->
        V.of_int63_exn (Int63.succ Int63.min_value));
      [%expect {|
        (raised (
          "Time_ns.Ofday.of_span_since_start_of_day_exn: input out of bounds"
          -53375d23h53m38.427387903s)) |}];
      show_raise ~hide_positions:true (fun () ->
        V.of_int63_exn (Int63.pred Int63.max_value));
      [%expect {|
        (raised (
          "Time_ns.Ofday.of_span_since_start_of_day_exn: input out of bounds"
          53375d23h53m38.427387902s)) |}];
    ;;

    let%test_unit "roundtrip quickcheck" =
      let generator =
        Core_kernel.Int63.gen_incl
          (V.to_int63 Time_ns.Ofday.start_of_day)
          (V.to_int63 Time_ns.Ofday.start_of_next_day)
        |> Core_kernel.Quickcheck.Generator.map ~f:V.of_int63_exn
      in
      Core_kernel.Quickcheck.test generator
        ~sexp_of:V.sexp_of_t
        ~f:(fun ofday ->
          [%test_result: V.t] ~expect:ofday (V.of_int63_exn (V.to_int63  ofday));
          [%test_result: V.t] ~expect:ofday (V.t_of_sexp    (V.sexp_of_t ofday)))
    ;;
  end)

let%test_module "Time_ns.Ofday.Option.Stable.V1" =
  (module struct
    module V = Time_ns.Ofday.Option.Stable.V1

    let%expect_test "stable conversions" =
      let make int64 = V.of_int63_exn (Int63.of_int64_exn int64) in
      (* stable checks for key values *)
      print_and_check_stable_int63able_type [%here] (module V) [
        make                           0L;
        make                           1L;
        make                         499L;
        make                         500L;
        make                       1_000L;
        make             123_456_789_012L;
        make             987_654_321_000L;
        make           1_234_560_000_000L;
        make          52_200_010_101_000L;
        make          86_399_999_999_000L;
        make          86_399_999_999_999L;
        make          86_400_000_000_000L;
        make (-4_611_686_018_427_387_904L); (* None *)
      ];
      [%expect {|
        (bin_shape_digest 2b528f4b22f08e28876ffe0239315ac2)
        ((sexp (00:00:00.000000000))
         (bin_io "\000")
         (int63  0))
        ((sexp (00:00:00.000000001))
         (bin_io "\001")
         (int63  1))
        ((sexp (00:00:00.000000499))
         (bin_io "\254\243\001")
         (int63  499))
        ((sexp (00:00:00.000000500))
         (bin_io "\254\244\001")
         (int63  500))
        ((sexp (00:00:00.000001000))
         (bin_io "\254\232\003")
         (int63  1000))
        ((sexp (00:02:03.456789012))
         (bin_io "\252\020\026\153\190\028\000\000\000")
         (int63  123456789012))
        ((sexp (00:16:27.654321000))
         (bin_io "\252h\243\200\244\229\000\000\000")
         (int63  987654321000))
        ((sexp (00:20:34.560000000))
         (bin_io "\252\000\160\130q\031\001\000\000")
         (int63  1234560000000))
        ((sexp (14:30:00.010101000))
         (bin_io "\252\b1\015\195y/\000\000")
         (int63  52200010101000))
        ((sexp (23:59:59.999999000))
         (bin_io "\252\024\252N\145\148N\000\000")
         (int63  86399999999000))
        ((sexp (23:59:59.999999999))
         (bin_io "\252\255\255N\145\148N\000\000")
         (int63  86399999999999))
        ((sexp (24:00:00.000000000))
         (bin_io "\252\000\000O\145\148N\000\000")
         (int63  86400000000000))
        ((sexp ())
         (bin_io "\252\000\000\000\000\000\000\000\192")
         (int63  -4611686018427387904)) |}];
      (* make sure [of_int63_exn] checks range *)
      show_raise ~hide_positions:true (fun () ->
        V.of_int63_exn (Int63.succ Int63.min_value));
      [%expect {|
        (raised (
          "Span.t exceeds limits"
          (t         -53375d23h53m38.427387903s)
          (min_value -49275d)
          (max_value 49275d))) |}];
      show_raise ~hide_positions:true (fun () ->
        V.of_int63_exn Int63.max_value);
      [%expect {|
        (raised (
          "Span.t exceeds limits"
          (t         53375d23h53m38.427387903s)
          (min_value -49275d)
          (max_value 49275d))) |}];
    ;;

    let%test_unit "roundtrip quickcheck" =
      let generator =
        Core_kernel.Int63.gen_incl
          (V.to_int63 (Time_ns.Ofday.Option.some Time_ns.Ofday.start_of_day))
          (V.to_int63 (Time_ns.Ofday.Option.some Time_ns.Ofday.start_of_next_day))
        |> Core_kernel.Quickcheck.Generator.map ~f:V.of_int63_exn
      in
      Core_kernel.Quickcheck.test generator
        ~sexp_of:V.sexp_of_t
        ~f:(fun ofday_option ->
          [%test_result: V.t] ~expect:ofday_option
            (V.of_int63_exn (V.to_int63 ofday_option));
          [%test_result: V.t] ~expect:ofday_option
            (V.t_of_sexp (V.sexp_of_t ofday_option)))
    ;;
  end)

let%test_module "Time_ns.Span" =
  (module struct
    open Time_ns.Span

    let half_microsecond = Int63.of_int 500

    let nearest_microsecond t =
      Int63.((Time_ns.Span.to_int63_ns t + half_microsecond) /% of_int 1000)
    ;;

    let min_span_ns_as_span = to_span Time_ns.Span.min_value
    let max_span_ns_as_span = to_span Time_ns.Span.max_value

    let%test "to_span +/-140y raises" =
      List.for_all [ 1.; -1. ]
        ~f:(fun sign ->
          does_raise (fun () ->
            to_span (Time_ns.Span.of_day (140. *. 366. *. sign))))
    ;;

    let%test "of_span +/-140y raises" =
      List.for_all [ 1.; -1. ]
        ~f:(fun sign ->
          does_raise (fun () -> of_span (Time.Span.of_day (140. *. 366. *. sign))))
    ;;

    let%test_unit "Span.to_string_hum" =
      let open Time_ns.Span in
      [%test_result: string] (to_string_hum nanosecond) ~expect:"1ns";
      [%test_result: string] (to_string_hum day) ~expect:"1d";
      [%test_result: string]
        (to_string_hum ~decimals:6                      day)
        ~expect:"1d";
      [%test_result: string]
        (to_string_hum ~decimals:6 ~align_decimal:false day)
        ~expect:"1d";
      [%test_result: string]
        (to_string_hum ~decimals:6 ~align_decimal:true  day)
        ~expect:"1.000000d ";
      [%test_result: string]
        (to_string_hum ~decimals:6 ~align_decimal:true ~unit_of_time:Day
           (hour + minute))
        ~expect:"0.042361d "

    let a_few_more_or_less = [-3; -2; -1; 0; 1; 2; 3]

    let span_examples =
      let open Time.Span in
      [
        min_span_ns_as_span;
        zero;
        microsecond;
        millisecond;
        second;
        minute;
        hour;
        day;
        scale day 365.;
        max_span_ns_as_span;
      ]
      @ List.init 9 ~f:(fun _ ->
        of_us (Random.float (to_us max_span_ns_as_span)))

    let multiples_of_span span =
      List.map a_few_more_or_less ~f:(fun factor ->
        Time.Span.scale span (float factor))

    let within_a_few_microseconds_of_span span =
      List.map a_few_more_or_less ~f:(fun number_of_microseconds ->
        Time.Span.( + ) span
          (Time.Span.scale Time.Span.microsecond (float number_of_microseconds)))

    let nearest_microsecond_to_span span =
      Time.Span.of_us (Float.round_nearest (Time.Span.to_us span))

    let span_is_in_range span =
      Time.Span.( >= ) span min_span_ns_as_span &&
      Time.Span.( <= ) span max_span_ns_as_span

    let%expect_test "Time.Span.t -> Time_ns.Span.t round trip" =
      let open Time.Span in
      let spans =
        span_examples
        |> List.concat_map ~f:multiples_of_span
        |> List.concat_map ~f:within_a_few_microseconds_of_span
        |> List.map        ~f:nearest_microsecond_to_span
        |> List.filter     ~f:span_is_in_range
        |> List.dedup_and_sort ~compare:Time.Span.compare
      in
      List.iter spans ~f:(fun span ->
        let span_ns    = of_span span    in
        let round_trip = to_span span_ns in
        let precision = abs (round_trip - span) in
        require [%here] (precision <= microsecond)
          ~if_false_then_print_s:
            (lazy [%message
              "round-trip does not have microsecond precision"
                (span       : Time.Span.t)
                (span_ns    : Core_kernel.Time_ns.Span.t)
                (round_trip : Time.Span.t)
                (precision  : Time.Span.t)]));
      [%expect {||}];
    ;;

    let span_ns_examples =
      let open Time_ns.Span in
      [
        min_value;
        zero;
        microsecond;
        millisecond;
        second;
        minute;
        hour;
        day;
        scale day 365.;
        max_value;
      ]
      @ List.init 9 ~f:(fun _ ->
        of_us (Random.float (to_us max_value)))

    let multiples_of_span_ns span_ns =
      List.filter_map a_few_more_or_less ~f:(fun factor ->
        Core.Option.try_with (fun () ->
          Time_ns.Span.scale span_ns (float factor)))

    let within_a_few_microseconds_of_span_ns span_ns =
      List.filter_map a_few_more_or_less ~f:(fun number_of_microseconds ->
        Core.Option.try_with (fun () ->
          Time_ns.Span.( + ) span_ns
            (Time_ns.Span.scale Time_ns.Span.microsecond (float number_of_microseconds))))

    let nearest_microsecond_to_span_ns span_ns =
      of_int63_ns (Int63.( * ) (nearest_microsecond span_ns) (Int63.of_int 1000))

    let span_ns_is_in_range span_ns =
      Time_ns.Span.( >= ) span_ns Time_ns.Span.min_value &&
      Time_ns.Span.( <= ) span_ns Time_ns.Span.max_value

    let%expect_test "Time_ns.Span.t -> Time.Span.t round trip" =
      let open Time_ns.Span in
      let span_nss =
        span_ns_examples
        |> List.concat_map ~f:multiples_of_span_ns
        |> List.concat_map ~f:within_a_few_microseconds_of_span_ns
        |> List.map        ~f:nearest_microsecond_to_span_ns
        |> List.filter     ~f:span_ns_is_in_range
        |> List.dedup_and_sort ~compare:Time_ns.Span.compare
      in
      List.iter span_nss ~f:(fun span_ns ->
        let span       = to_span span_ns in
        let round_trip = of_span span    in
        let precision = abs (round_trip - span_ns) in
        require [%here] (precision <= microsecond)
          ~if_false_then_print_s:
            (lazy [%message
              "round-trip does not have microsecond precision"
                (span_ns    : Core_kernel.Time_ns.Span.t)
                (span       : Time.Span.t)
                (round_trip : Core_kernel.Time_ns.Span.t)
                (precision  : Core_kernel.Time_ns.Span.t)]));
      [%expect {||}];
    ;;

    let%test _ = Time.Span.is_positive (to_span max_value)  (* make sure no overflow *)
  end)

let%test_module "Time_ns.Span.Option" =
  (module struct
    open Time_ns.Span.Option

    let%test "none is not a valid span" =
      does_raise (fun () ->
        some (Time_ns.Span.of_int63_ns (Time_ns.Span.Option.Stable.V1.to_int63 none)))
  end)

let%test_module "Time_ns" =
  (module struct
    open Time_ns

    let min_time_value = to_time min_value
    let max_time_value = to_time max_value

    let%test_unit "Time.t -> Time_ns.t round trip" =
      let open Time in
      let time_to_float t = Time.to_span_since_epoch t |> Time.Span.to_sec in
      let sexp_of_t t = [%sexp_of: t * float] (t, time_to_float t) in (* more precise *)
      let us_since_epoch time = Time.(Span.to_us (diff time epoch)) in
      let min_us_since_epoch = us_since_epoch min_time_value in
      let max_us_since_epoch = us_since_epoch max_time_value in
      let time_of_us_since_epoch us_since_epoch =
        Time.(add epoch (Span.of_us (Float.round_nearest us_since_epoch)))
      in
      let times =                           (* touchstones *)
        [ min_time_value; Time.epoch; Time.now (); max_time_value ]
      in
      let times =                           (* a few units around *)
        List.concat_map times
          ~f:(fun time ->
            List.concat_map
              Time.Span.([ microsecond; millisecond; second; minute; hour; day;
                           scale day 365.
                         ])
              ~f:(fun unit ->
                List.map (List.map ~f:float (List.range (-3) 4))
                  ~f:(fun s -> Time.add time (Time.Span.scale unit s))))
      in
      let times =                           (* a few randoms *)
        times @
        List.init 9
          ~f:(fun _ ->
            Time.add Time.epoch
              (Time.Span.of_us
                 (min_us_since_epoch
                  +. Random.float (max_us_since_epoch -. min_us_since_epoch))))
      in
      let times =                           (* nearest microsecond *)
        List.map times
          ~f:(fun time ->
            time_of_us_since_epoch
              (Float.round_nearest Time.(Span.to_us (diff time epoch))))
      in
      let times =                           (* in range *)
        List.filter times
          ~f:(fun time -> Time.(time >= min_time_value && time <= max_time_value))
      in
      let is_64bit = match Word_size.word_size with
        | W64 -> true
        | W32 -> false
      in
      List.iter times
        ~f:(fun expect ->
          let time = to_time (of_time expect) in
          (* We don't have full microsecond precision at the far end of the range. *)
          if is_64bit && expect < Time.of_string "2107-01-01 00:00:00" then
            [%test_result: t] ~expect time
          else
            [%test_pred: t * t]
              (fun (a, b) -> Span.(abs (diff a b) <= microsecond))
              (expect, time))
    ;;

    let%test_unit "Time_ns.t -> Time.t round trip" =
      let open Core_kernel.Time_ns.Alternate_sexp in
      let ts =                              (* touchstones *)
        [ min_value; epoch; now (); max_value ]
      in
      (* Some tweaks will be out of range, which will raise exceptions. *)
      let filter_map list ~f =
        List.filter_map list ~f:(fun x -> Core.Option.try_with (fun () -> f x))
      in
      let ts =                              (* a few units around *)
        List.concat_map ts
          ~f:(fun time ->
            List.concat_map
              Span.([ microsecond; millisecond; second; minute; hour; day;
                      scale day 365.
                    ])
              ~f:(fun unit ->
                filter_map (List.map ~f:float (List.range (-3) 4))
                  ~f:(fun s -> add time (Span.scale unit s))))
      in
      let ts =                              (* a few randoms *)
        ts @ List.init 9 ~f:(fun _ -> random ())
      in
      let ts =                              (* nearest microsecond since epoch *)
        List.map ts
          ~f:(fun time ->
            Time_ns.of_int63_ns_since_epoch
              (let open Int63 in
               (Time_ns.to_int63_ns_since_epoch time + of_int 500)
               /% of_int 1000
               * of_int 1000))
      in
      let ts =                              (* in range *)
        List.filter ts ~f:(fun t -> t >= min_value && t <= max_value)
      in
      List.iter ts ~f:(fun expect -> [%test_result: t] ~expect (of_time (to_time expect)))
    ;;

    let%test _ = epoch = of_span_since_epoch Span.zero

    let%test_unit "round trip from [Time.t] to [t] and back" =
      let time_of_float f = Time.of_span_since_epoch (Time.Span.of_sec f) in
      let times = List.map ~f:time_of_float [ 0.0; 1.0; 1.123456789 ] in
      List.iter times ~f:(fun time ->
        let res = to_time (of_time time) in
        [%test_result: Time.t] ~equal:Time.(=.) ~expect:time res
      )

    let%test_unit "round trip from [t] to [Time.t] and back" =
      List.iter Span.([ zero; second; scale day 365. ]) ~f:(fun since_epoch ->
        let t = of_span_since_epoch since_epoch in
        let res = of_time (to_time t) in
        (* Allow up to 100ns discrepancy in a year due to float precision issues. *)
        let discrepancy = diff res t in
        if Span.(abs discrepancy > of_ns 100.) then
          failwiths "Failed on span since epoch"
            (`since_epoch since_epoch, t, `res res, `discrepancy discrepancy)
            [%sexp_of: [ `since_epoch of Span.t ]
                       * t * [ `res of t ]
                       * [ `discrepancy of Span.t ]])

    let%test_unit _ =
      let span = Span.create ~hr:8 ~min:27 ~sec:14 ~ms:359 () in
      let ofday = Ofday.of_span_since_start_of_day_exn span in
      let expected = "08:27:14.359" in
      let ms_str = Ofday.to_millisecond_string ofday in
      if String.(<>) ms_str expected then
        failwithf "Failed on Ofday.to_millisecond_string Got (%s) expected (%s)"
          ms_str expected ()

    let check ofday =
      try
        assert Ofday.(ofday >= start_of_day && ofday < start_of_next_day);
        [%test_result: Ofday.t] ~expect:ofday
          (Ofday.of_string (Ofday.to_string ofday));
        [%test_result: Ofday.t] ~expect:ofday
          (Ofday.t_of_sexp (Ofday.sexp_of_t ofday));
        let of_ofday = Ofday.of_ofday (Ofday.to_ofday ofday) in
        let diff = Span.abs (Ofday.diff ofday of_ofday) in
        if Span.( >= ) diff Span.microsecond then
          raise_s [%message
            "of_ofday / to_ofday round-trip failed"
              (ofday    : Ofday.t)
              (of_ofday : Ofday.t)]
      with raised ->
        failwiths "check ofday"
          (Or_error.try_with (fun () -> [%sexp_of: Ofday.t] ofday),
           Span.to_int63_ns (Time_ns.Ofday.to_span_since_start_of_day ofday),
           raised)
          [%sexp_of: Sexp.t Or_error.t * Int63.t * exn]

    let%test_unit _ =
      (* Ensure that midnight_cache doesn't interfere with converting times that are much
         earlier or later than each other. *)
      check (to_ofday ~zone:(force Time_ns.Zone.local) epoch);
      check (to_ofday ~zone:(force Time_ns.Zone.local) (now ()));
      check (to_ofday ~zone:(force Time_ns.Zone.local) epoch)

    (* Reproduce a failure of the prior test before taking DST into account. *)
    let%test_unit "to_ofday around fall 2015 DST transition" =
      List.iter
        ~f:(fun (time_ns, expect) ->
          let zone = Time.Zone.find_exn "US/Eastern" in
          (* First make sure Time.to_ofday behaves as expected with these inputs. *)
          let time_ofday = Time.to_ofday (to_time time_ns) ~zone in
          if Time.Ofday.(<>) time_ofday (Time.Ofday.of_string expect) then
            failwiths "Time.to_ofday"
              [%sexp (time_ns    : t),
                     (time_ofday : Time.Ofday.t),
                     (expect     : string)]
              Fn.id;
          (* Then make sure we do the same, correct thing. *)
          let ofday = to_ofday time_ns ~zone in
          check ofday;
          if Ofday.(<>) ofday (Ofday.of_string expect) then
            failwiths "to_ofday"
              [%sexp (time_ns : t),
                     (ofday   : Ofday.t),
                     (expect  : string)]
              Fn.id)
        ([ epoch, "19:00:00"
         ; of_string_abs "2015-11-02 23:59:59 US/Eastern", "23:59:59"
         ; epoch, "19:00:00"
         (* [of_string] chooses the second occurrence of a repeated wall clock time in a
            DST (Daylight Saving Time) transition. *)
         ; add (of_string "2015-11-01 01:59:59 US/Eastern") Span.second, "02:00:00"
         ]
         (* We can denote specific linear times during the repeated wall-clock hour
            relative to a time before the ambiguity. *)
         @ List.map
             ~f:(fun (span, ofday) ->
               add (of_string "2015-11-01 00:59:59 US/Eastern") span, ofday)
             [ Span.second,          "01:00:00"
             ; Span.(second + hour), "01:00:00"
             ]
         @ [ add (of_string "2015-03-08 01:59:59 US/Eastern") Span.second, "03:00:00"
           ; epoch, "19:00:00"
           ])

    let random_nativeint_range =
      match Word_size.word_size with
      | W64 -> fun () -> random ()
      | W32 ->
        (* In 32 bits, some functions in [Time] don't work on all the float values, but
           only the part that fits in a native int. *)
        let in_ns = Int63.of_float 1e9 in
        let max_time_ns = Int63.(of_nativeint_exn Nativeint.max_value * in_ns) in
        let min_time_ns = Int63.(of_nativeint_exn Nativeint.min_value * in_ns) in
        let range = Int63.(one + max_time_ns - min_time_ns) in
        fun () ->
          let r = Time_ns.to_int63_ns_since_epoch (random ()) in
          Time_ns.of_int63_ns_since_epoch
            Int63.(((r - min_time_ns) % range) + min_time_ns)
    ;;

    let%test_unit "to_ofday random" =
      List.iter !Time.Zone.likely_machine_zones ~f:(fun zone ->
        let zone = Time.Zone.find_exn zone in
        for _ = 0 to 1_000 do check (to_ofday (random_nativeint_range ()) ~zone) done)

    let%test_unit "to_ofday ~zone:(force Time_ns.Zone.local) random" =
      for _ = 0 to 1_000 do check (to_ofday ~zone:(force Time_ns.Zone.local) (random_nativeint_range ())) done

    let%expect_test "[to_date ofday] - [of_date_ofday] roundtrip" =
      let times =
        (* midnight EDT on 2016-11-01 +/- 1ns and 2ns *)
        [ 1477972799999999998L
        ; 1477972799999999999L
        ; 1477972800000000000L
        ; 1477972800000000001L
        ; 1477972800000000002L
        (* two timestamps on 2016-11-01 in the middle of the day, 1ns apart *)
        ; 1478011075019386869L
        ; 1478011075019386670L
        (* two timestamps on 2016-11-06 (Sunday), when DST ends at 2am. When DST ends, time
           jumps from 2:00am back to 1:00am. Hence there are two 1:00ams, the later occurs 1hr
           later in linear time. This test starts with the initial 1:00am (as inputs to
           [to_date] and [to_ofday]) and then gets reinterpreted as the later 1:00am by
           [of_date_ofday] *)
        ; 1478408399999999999L (* just before 1am *)
        ; 1478408400000000000L (* 1ns later, at 1am (for the first time),
                                  NOTE: we're off by 1h when we try the round-trip, see
                                  [3600000000000] in the expect_test below.  *)
        ; 1478412000000000000L (* 1h later, which is 1am again (this time we round-trip) *)
        ; 1478412000000000001L (* another 1ns later *)
        ]
      in
      let zone = Time.Zone.of_string "America/New_York" in
      List.iter times ~f:(fun ns ->
        let t = Int63.of_int64_exn ns |> Time_ns.of_int63_ns_since_epoch in
        let date = to_date t ~zone in
        let ofday = to_ofday t ~zone in
        let t' = of_date_ofday ~zone date ofday in
        printf !"%{Date} %{Ofday} %{Int64} %{Int64}\n"
          date
          ofday
          ns
          (Int64.(-) (to_int63_ns_since_epoch t' |> Int63.to_int64) ns));
      [%expect {|
        2016-10-31 23:59:59.999999998 1477972799999999998 0
        2016-10-31 23:59:59.999999999 1477972799999999999 0
        2016-11-01 00:00:00.000000000 1477972800000000000 0
        2016-11-01 00:00:00.000000001 1477972800000000001 0
        2016-11-01 00:00:00.000000002 1477972800000000002 0
        2016-11-01 10:37:55.019386869 1478011075019386869 0
        2016-11-01 10:37:55.019386670 1478011075019386670 0
        2016-11-06 00:59:59.999999999 1478408399999999999 0
        2016-11-06 01:00:00.000000000 1478408400000000000 3600000000000
        2016-11-06 01:00:00.000000000 1478412000000000000 0
        2016-11-06 01:00:00.000000001 1478412000000000001 0 |}]
    ;;

    let%expect_test "in tests, [to_string] uses NYC's time zone" =
      printf "%s" (to_string epoch);
      [%expect {| 1969-12-31 19:00:00.000000-05:00 |}];
    ;;

    let%expect_test "in tests, [sexp_of_t] uses NYC's time zone" =
      printf !"%{Sexp}" [%sexp (epoch : t)];
      [%expect {| (1969-12-31 19:00:00.000000-05:00) |}];
    ;;
  end)

module Ofday_zoned = struct
  open Time_ns.Ofday.Zoned

  let%expect_test _ =
    let test string =
      let t = of_string string in
      let round_trip x =
        require_compare_equal [%here] (module With_nonchronological_compare) t x
      in
      round_trip (of_string (to_string t));
      round_trip (t_of_sexp (sexp_of_t t));
    in
    test "12:00 nyc";
    test "12:00 America/New_York";
    [%expect {| |}];
  ;;

  let%expect_test "Zoned.V1" =
    print_and_check_stable_type [%here]
      (module Time_ns.Stable.Ofday.Zoned.V1)
      zoned_examples;
    [%expect {|
      (bin_shape_digest 116be3b907c3a1807e5fbf3e7677c018)
      ((sexp (00:00:00.000000000 UTC)) (bin_io "\000\003UTC"))
      ((sexp (00:00:00.000000001 UTC)) (bin_io "\001\003UTC"))
      ((sexp (00:00:00.000001000 UTC)) (bin_io "\254\232\003\003UTC"))
      ((sexp (00:00:00.001000000 UTC)) (bin_io "\253@B\015\000\003UTC"))
      ((sexp (00:00:01.000000000 UTC)) (bin_io "\253\000\202\154;\003UTC"))
      ((sexp (00:01:00.000000000 UTC))
       (bin_io "\252\000XG\248\r\000\000\000\003UTC"))
      ((sexp (01:00:00.000000000 UTC))
       (bin_io "\252\000\160\1840F\003\000\000\003UTC"))
      ((sexp (23:00:00.000000000 UTC)) (bin_io "\252\000`\150`NK\000\000\003UTC"))
      ((sexp (23:59:00.000000000 UTC))
       (bin_io "\252\000\168\007\153\134N\000\000\003UTC"))
      ((sexp (23:59:59.000000000 UTC))
       (bin_io "\252\0006\180U\148N\000\000\003UTC"))
      ((sexp (23:59:59.999000000 UTC))
       (bin_io "\252\192\189?\145\148N\000\000\003UTC"))
      ((sexp (23:59:59.999999000 UTC))
       (bin_io "\252\024\252N\145\148N\000\000\003UTC"))
      ((sexp (23:59:59.999999999 UTC))
       (bin_io "\252\255\255N\145\148N\000\000\003UTC"))
      ((sexp (24:00:00.000000000 UTC))
       (bin_io "\252\000\000O\145\148N\000\000\003UTC"))
      ((sexp (00:00:00.000000000 America/New_York))
       (bin_io "\000\016America/New_York"))
      ((sexp (00:00:00.000000001 America/New_York))
       (bin_io "\001\016America/New_York"))
      ((sexp (00:00:00.000001000 America/New_York))
       (bin_io "\254\232\003\016America/New_York"))
      ((sexp (00:00:00.001000000 America/New_York))
       (bin_io "\253@B\015\000\016America/New_York"))
      ((sexp (00:00:01.000000000 America/New_York))
       (bin_io "\253\000\202\154;\016America/New_York"))
      ((sexp (00:01:00.000000000 America/New_York))
       (bin_io "\252\000XG\248\r\000\000\000\016America/New_York"))
      ((sexp (01:00:00.000000000 America/New_York))
       (bin_io "\252\000\160\1840F\003\000\000\016America/New_York"))
      ((sexp (23:00:00.000000000 America/New_York))
       (bin_io "\252\000`\150`NK\000\000\016America/New_York"))
      ((sexp (23:59:00.000000000 America/New_York))
       (bin_io "\252\000\168\007\153\134N\000\000\016America/New_York"))
      ((sexp (23:59:59.000000000 America/New_York))
       (bin_io "\252\0006\180U\148N\000\000\016America/New_York"))
      ((sexp (23:59:59.999000000 America/New_York))
       (bin_io "\252\192\189?\145\148N\000\000\016America/New_York"))
      ((sexp (23:59:59.999999000 America/New_York))
       (bin_io "\252\024\252N\145\148N\000\000\016America/New_York"))
      ((sexp (23:59:59.999999999 America/New_York))
       (bin_io "\252\255\255N\145\148N\000\000\016America/New_York"))
      ((sexp (24:00:00.000000000 America/New_York))
       (bin_io "\252\000\000O\145\148N\000\000\016America/New_York")) |}];
  ;;
end

let%expect_test "end-of-day constants" =
  let zones = List.map !Time_ns.Zone.likely_machine_zones ~f:Time_ns.Zone.find_exn in
  let test_round_trip zone date ofday ~expect =
    require_equal [%here] (module Date)
      (Time_ns.of_date_ofday ~zone date ofday |> Time_ns.to_date ~zone)
      expect
      ~message:(Time_ns.Zone.name zone)
  in
  let test date_string =
    let date = Date.of_string date_string in
    List.iter zones ~f:(fun zone ->
      test_round_trip zone date Time_ns.Ofday.approximate_end_of_day
        ~expect:date;
      test_round_trip zone date Time_ns.Ofday.start_of_next_day
        ~expect:(Date.add_days date 1));
  in
  test "1970-01-01";
  test "2013-10-07";
  test "2099-12-31";
  test "2101-04-01";
  [%expect {||}];
;;

let%test_module "Time_ns.Option" =
  (module struct
    open Time_ns.Option

    let%test_module "round trip" =
      (module struct
        let roundtrip t = (value_exn (some t))
        let%test_unit "epoch" =
          [%test_result: Time_ns.t] (roundtrip Time_ns.epoch) ~expect:Time_ns.epoch
        let%test_unit "now" =
          let t = Time_ns.now () in [%test_result: Time_ns.t] (roundtrip t) ~expect:t
      end)

    let%test _ = is_error (Result.try_with (fun () -> value_exn none))
  end)

let%expect_test _ =
  print_and_check_container_sexps [%here] (module Time_ns) [
    Time_ns.epoch;
    Time_ns.of_string "1955-11-12 18:38:00-08:00";
    Time_ns.of_string "1985-10-26 21:00:00-08:00";
    Time_ns.of_string "2015-10-21 19:28:00-08:00";
  ];
  [%expect {|
    (Set (
      (1955-11-12 21:38:00.000000-05:00)
      (1969-12-31 19:00:00.000000-05:00)
      (1985-10-27 01:00:00.000000-04:00)
      (2015-10-21 23:28:00.000000-04:00)))
    (Map (
      ((1955-11-12 21:38:00.000000-05:00) 1)
      ((1969-12-31 19:00:00.000000-05:00) 0)
      ((1985-10-27 01:00:00.000000-04:00) 2)
      ((2015-10-21 23:28:00.000000-04:00) 3)))
    (Hash_set (
      (1955-11-12 21:38:00.000000-05:00)
      (1969-12-31 19:00:00.000000-05:00)
      (1985-10-27 01:00:00.000000-04:00)
      (2015-10-21 23:28:00.000000-04:00)))
    (Table (
      ((1955-11-12 21:38:00.000000-05:00) 1)
      ((1969-12-31 19:00:00.000000-05:00) 0)
      ((1985-10-27 01:00:00.000000-04:00) 2)
      ((2015-10-21 23:28:00.000000-04:00) 3))) |}];
;;

let%expect_test _ =
  print_and_check_container_sexps [%here] (module Time_ns.Option) [
    Time_ns.Option.none;
    Time_ns.Option.some (Time_ns.epoch);
    Time_ns.Option.some (Time_ns.of_string "1955-11-12 18:38:00-08:00");
    Time_ns.Option.some (Time_ns.of_string "1985-10-26 21:00:00-08:00");
    Time_ns.Option.some (Time_ns.of_string "2015-10-21 19:28:00-08:00");
  ];
  [%expect {|
    (Set (
      ()
      ((1955-11-12 21:38:00.000000-05:00))
      ((1969-12-31 19:00:00.000000-05:00))
      ((1985-10-27 01:00:00.000000-04:00))
      ((2015-10-21 23:28:00.000000-04:00))))
    (Map (
      (() 0)
      (((1955-11-12 21:38:00.000000-05:00)) 2)
      (((1969-12-31 19:00:00.000000-05:00)) 1)
      (((1985-10-27 01:00:00.000000-04:00)) 3)
      (((2015-10-21 23:28:00.000000-04:00)) 4)))
    (Hash_set (
      ()
      ((1955-11-12 21:38:00.000000-05:00))
      ((1969-12-31 19:00:00.000000-05:00))
      ((1985-10-27 01:00:00.000000-04:00))
      ((2015-10-21 23:28:00.000000-04:00))))
    (Table (
      (() 0)
      (((1955-11-12 21:38:00.000000-05:00)) 2)
      (((1969-12-31 19:00:00.000000-05:00)) 1)
      (((1985-10-27 01:00:00.000000-04:00)) 3)
      (((2015-10-21 23:28:00.000000-04:00)) 4))) |}];
;;

let%expect_test _ =
  print_and_check_container_sexps [%here] (module Time_ns.Span) [
    Time_ns.Span.zero;
    Time_ns.Span.of_string "101.5ms";
    Time_ns.Span.of_string "3.125s";
    Time_ns.Span.of_string "252d";
  ];
  [%expect {|
    (Set (0s 101.5ms 3.125s 252d))
    (Map (
      (0s      0)
      (101.5ms 1)
      (3.125s  2)
      (252d    3)))
    (Hash_set (0s 101.5ms 3.125s 252d))
    (Table (
      (0s      0)
      (101.5ms 1)
      (3.125s  2)
      (252d    3))) |}]
;;

let%expect_test _ =
  print_and_check_container_sexps [%here] (module Time_ns.Span.Option) [
    Time_ns.Span.Option.none;
    Time_ns.Span.Option.some (Time_ns.Span.zero);
    Time_ns.Span.Option.some (Time_ns.Span.of_string "101.5ms");
    Time_ns.Span.Option.some (Time_ns.Span.of_string "3.125s");
    Time_ns.Span.Option.some (Time_ns.Span.of_string "252d");
  ];
  [%expect {|
    (Set (
      ()
      (0s)
      (101.5ms)
      (3.125s)
      (252d)))
    (Map (
      (() 0)
      ((0s)      1)
      ((101.5ms) 2)
      ((3.125s)  3)
      ((252d)    4)))
    (Hash_set (
      ()
      (0s)
      (101.5ms)
      (3.125s)
      (252d)))
    (Table (
      (() 0)
      ((0s)      1)
      ((101.5ms) 2)
      ((3.125s)  3)
      ((252d)    4))) |}];
;;

let%expect_test _ =
  print_and_check_container_sexps [%here] (module Time_ns.Ofday) [
    Time_ns.Ofday.start_of_day;
    Time_ns.Ofday.of_string "18:38:00";
    Time_ns.Ofday.of_string "21:00:00";
    Time_ns.Ofday.of_string "19:28:00";
  ];
  [%expect {|
    (Set (
      00:00:00.000000000 18:38:00.000000000 19:28:00.000000000 21:00:00.000000000))
    (Map (
      (00:00:00.000000000 0)
      (18:38:00.000000000 1)
      (19:28:00.000000000 3)
      (21:00:00.000000000 2)))
    (Hash_set (
      00:00:00.000000000 18:38:00.000000000 19:28:00.000000000 21:00:00.000000000))
    (Table (
      (00:00:00.000000000 0)
      (18:38:00.000000000 1)
      (19:28:00.000000000 3)
      (21:00:00.000000000 2))) |}];
;;

let%expect_test _ =
  print_and_check_container_sexps [%here] (module Time_ns.Ofday.Option) [
    Time_ns.Ofday.Option.none;
    Time_ns.Ofday.Option.some (Time_ns.Ofday.start_of_day);
    Time_ns.Ofday.Option.some (Time_ns.Ofday.of_string "18:38:00");
    Time_ns.Ofday.Option.some (Time_ns.Ofday.of_string "21:00:00");
    Time_ns.Ofday.Option.some (Time_ns.Ofday.of_string "19:28:00");
  ];
  [%expect {|
    (Set (
      ()
      (00:00:00.000000000)
      (18:38:00.000000000)
      (19:28:00.000000000)
      (21:00:00.000000000)))
    (Map (
      (() 0)
      ((00:00:00.000000000) 1)
      ((18:38:00.000000000) 2)
      ((19:28:00.000000000) 4)
      ((21:00:00.000000000) 3)))
    (Hash_set (
      ()
      (00:00:00.000000000)
      (18:38:00.000000000)
      (19:28:00.000000000)
      (21:00:00.000000000)))
    (Table (
      (() 0)
      ((00:00:00.000000000) 1)
      ((18:38:00.000000000) 2)
      ((19:28:00.000000000) 4)
      ((21:00:00.000000000) 3))) |}];
;;

let%expect_test "time ns zone offset parsing" =
  let to_string t = Time_ns.to_string_abs ~zone:Time_ns.Zone.utc t in
  let test string =
    print_endline (to_string (Time_ns.of_string string));
  in
  test "2000-01-01 12:34:56.789012-00:00";
  test "2000-01-01 12:34:56.789012-0:00";
  test "2000-01-01 12:34:56.789012-00";
  test "2000-01-01 12:34:56.789012-0";
  [%expect {|
    2000-01-01 12:34:56.789012Z
    2000-01-01 12:34:56.789012Z
    2000-01-01 12:34:56.789012Z
    2000-01-01 12:34:56.789012Z |}];
  test "2000-01-01 12:34:56.789012-05:00";
  test "2000-01-01 12:34:56.789012-5:00";
  test "2000-01-01 12:34:56.789012-05";
  test "2000-01-01 12:34:56.789012-5";
  [%expect {|
    2000-01-01 17:34:56.789012Z
    2000-01-01 17:34:56.789012Z
    2000-01-01 17:34:56.789012Z
    2000-01-01 17:34:56.789012Z |}];
  test "2000-01-01 12:34:56.789012-23:00";
  test "2000-01-01 12:34:56.789012-23";
  [%expect {|
    2000-01-02 11:34:56.789012Z
    2000-01-02 11:34:56.789012Z |}];
  test "2000-01-01 12:34:56.789012-24:00";
  test "2000-01-01 12:34:56.789012-24";
  [%expect {|
    2000-01-02 12:34:56.789012Z
    2000-01-02 12:34:56.789012Z |}];
;;

let%expect_test "time ns zone invalid offset parsing" =
  let test here string =
    require_does_raise here (fun () ->
      Time_ns.of_string string)
  in
  test [%here] "2000-01-01 12:34:56.789012-0:";
  test [%here] "2000-01-01 12:34:56.789012-00:";
  test [%here] "2000-01-01 12:34:56.789012-0:0";
  test [%here] "2000-01-01 12:34:56.789012-00:0";
  test [%here] "2000-01-01 12:34:56.789012-:";
  test [%here] "2000-01-01 12:34:56.789012-:00";
  test [%here] "2000-01-01 12:34:56.789012-";
  [%expect {|
    (time.ml.Make.Time_of_string
     "2000-01-01 12:34:56.789012-0:"
     ("Time.Ofday: invalid string"
      0:
      "expected colon or am/pm suffix with optional space after minutes"))
    (time.ml.Make.Time_of_string
     "2000-01-01 12:34:56.789012-00:"
     ("Time.Ofday: invalid string"
      00:
      "expected colon or am/pm suffix with optional space after minutes"))
    (time.ml.Make.Time_of_string
     "2000-01-01 12:34:56.789012-0:0"
     ("Time.Ofday: invalid string"
      0:0
      "expected colon or am/pm suffix with optional space after minutes"))
    (time.ml.Make.Time_of_string
     "2000-01-01 12:34:56.789012-00:0"
     ("Time.Ofday: invalid string"
      00:0
      "expected colon or am/pm suffix with optional space after minutes"))
    (time.ml.Make.Time_of_string
     "2000-01-01 12:34:56.789012-:"
     (Invalid_argument "index out of bounds"))
    (time.ml.Make.Time_of_string
     "2000-01-01 12:34:56.789012-:00"
     (Failure "Char.get_digit_exn ':': not a digit"))
    (time.ml.Make.Time_of_string
     "2000-01-01 12:34:56.789012-"
     (Invalid_argument "index out of bounds")) |}];
  test [%here] "2000-01-01 12:34:56.789012-25:00";
  test [%here] "2000-01-01 12:34:56.789012-25";
  [%expect {|
    (time.ml.Make.Time_of_string
     "2000-01-01 12:34:56.789012-25:00"
     ("Time.Ofday: invalid string" 25:00 "hours out of bounds"))
    (time.ml.Make.Time_of_string
     "2000-01-01 12:34:56.789012-25"
     ("Time.Ofday: invalid string" 25:00 "hours out of bounds")) |}];
  test [%here] "2000-01-01 12:34:56.789012--1:00";
  test [%here] "2000-01-01 12:34:56.789012--1";
  [%expect {|
    (time.ml.Make.Time_of_string
     "2000-01-01 12:34:56.789012--1:00"
     (Failure "Char.get_digit_exn '-': not a digit"))
    (time.ml.Make.Time_of_string
     "2000-01-01 12:34:56.789012--1"
     (Invalid_argument "index out of bounds")) |}];
;;

let%expect_test "Span.randomize" =
  let module Span = Time_ns.Span in
  let span = Span.of_sec 1.  in
  let upper_bound = Span.of_sec 1.3 in
  let lower_bound = Span.of_sec 0.7 in
  let percent = Percent.of_mult 0.3 in
  let rec loop ~count ~trials =
    let open Int.O in
    if count >= trials
    then begin
      print_s [%message "succeeded" (count : int)]
    end
    else begin
      let rand = Span.randomize span ~percent in
      if (Span.( < ) rand lower_bound || Span.( > ) rand upper_bound)
      then begin
        print_cr [%here] [%message
          "out of bounds"
            (percent : Percent.t)
            (rand : Span.t)
            (lower_bound : Span.t)
            (upper_bound : Span.t)]
      end
      else begin
        loop ~count:(count + 1) ~trials
      end
    end
  in
  loop ~count:0 ~trials:1_000;
  [%expect {| (succeeded (count 1000)) |}];
;;

let%expect_test "Span.to_short_string" =
  let module Span = Time_ns.Span in
  let examples =
    let magnitudes = [1.; Float.pi; 10.6] in
    let pos_examples =
      List.concat_map magnitudes ~f:(fun magnitude ->
        List.map Unit_of_time.all ~f:(fun unit_of_time ->
          Span.scale (Span.of_unit_of_time unit_of_time) magnitude))
    in
    let signed_examples =
      List.concat_map pos_examples ~f:(fun span ->
        [span; Span.neg span])
    in
    Span.zero :: signed_examples
  in
  let alist =
    List.map examples ~f:(fun span ->
      (span, Span.to_short_string span))
  in
  print_s [%sexp (alist : (Span.t * string) list)];
  [%expect {|
    ((0s                    0ns)
     (1ns                   1ns)
     (-1ns                  -1ns)
     (1us                   1us)
     (-1us                  -1us)
     (1ms                   1ms)
     (-1ms                  -1ms)
     (1s                    1s)
     (-1s                   -1s)
     (1m                    1m)
     (-1m                   -1m)
     (1h                    1h)
     (-1h                   -1h)
     (1d                    1d)
     (-1d                   -1d)
     (3ns                   3ns)
     (-3ns                  -3ns)
     (3.142us               3.1us)
     (-3.142us              -3.1us)
     (3.141593ms            3.1ms)
     (-3.141593ms           -3.1ms)
     (3.141592654s          3.1s)
     (-3.141592654s         -3.1s)
     (3m8.495559215s        3.1m)
     (-3m8.495559215s       -3.1m)
     (3h8m29.733552923s     3.1h)
     (-3h8m29.733552923s    -3.1h)
     (3d3h23m53.605270158s  3.1d)
     (-3d3h23m53.605270158s -3.1d)
     (11ns                  11ns)
     (-11ns                 -11ns)
     (10.6us                10us)
     (-10.6us               -10us)
     (10.6ms                10ms)
     (-10.6ms               -10ms)
     (10.6s                 10s)
     (-10.6s                -10s)
     (10m36s                10m)
     (-10m36s               -10m)
     (10h36m                10h)
     (-10h36m               -10h)
     (10d14h24m             10d)
     (-10d14h24m            -10d)) |}];
;;

let%expect_test "times with implicit zones" =
  let test f =
    show_raise (fun () ->
      print_endline (Time_ns.to_string (f ())))
  in
  test (fun () ->
    Time_ns.Stable.V1.t_of_sexp (Sexp.Atom "2013-10-07 09:30:00"));
  [%expect {|
    2013-10-07 09:30:00.000000-04:00
    "did not raise" |}];
  test (fun () ->
    Time_ns.t_of_sexp (Sexp.Atom "2013-10-07 09:30:00"));
  [%expect {|
    2013-10-07 09:30:00.000000-04:00
    "did not raise" |}];
  test (fun () ->
    Time_ns.of_string "2013-10-07 09:30:00");
  [%expect {|
    2013-10-07 09:30:00.000000-04:00
    "did not raise" |}];
;;
