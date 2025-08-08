import gleam/option.{None, Some}
import parser
import simplifile

const data_path = "./test/data/"

/// Tests parse_updates_from_email on an email containing a single chapter
pub fn parse_updates_from_email_single_chapter_test() {
  let expected =
    parser.NewChapter(
      parser.DetailedWork(
        789_141,
        "Some Nameless Work (Break things)(",
        "ArcOnyx and FakeUser",
        "3/?",
        "Glee - Unit Testing",
        "General",
        "Choose Not To Use Archive Warnings",
        Some("Part 1 of Series Name"),
        Some("A summary of the fic\nSplit across\n\nmany lines."),
      ),
      1_414_155,
      "Chapter 3: Hi There (4072 words)",
      None,
    )

  let assert Ok(body) =
    simplifile.read(data_path <> "email_body_single_chapter.txt")

  let assert Ok(updates) = parser.parse_updates_from_email(body)

  let assert [update] = updates
  assert expected == update
}

pub fn parse_updates_from_email_single_chapter_with_chap_summary_test() {
  let expected =
    parser.NewChapter(
      parser.DetailedWork(
        789_141,
        "Some Nameless Work (Break things)(",
        "ArcOnyx and FakeUser",
        "3/?",
        "Glee - Unit Testing",
        "General",
        "Choose Not To Use Archive Warnings",
        Some("Part 1 of Series Name"),
        Some("A summary of the fic\nSplit across\n\nmany lines."),
      ),
      1_414_155,
      "Chapter 3: Hi There (4072 words)",
      Some("This is a three\n\nline chapter summary"),
    )

  let assert Ok(body) =
    simplifile.read(
      data_path <> "email_body_single_chapter_with_chap_summary.txt",
    )

  let assert Ok(updates) = parser.parse_updates_from_email(body)

  let assert [update] = updates
  assert expected == update
}

pub fn parse_updates_from_email_single_chapter_partial_one_test() {
  let expected =
    parser.NewChapter(
      parser.DetailedWork(
        789_141,
        "Some Nameless Work (Break things)(",
        "ArcOnyx and FakeUser",
        "3/?",
        "Glee - Unit Testing",
        "General",
        "Choose Not To Use Archive Warnings",
        Some("Part 1 of Series Name"),
        None,
      ),
      1_414_155,
      "Chapter 3: Hi There (4072 words)",
      Some("This is a three\n\nline chapter summary"),
    )

  let assert Ok(body) =
    simplifile.read(data_path <> "email_body_single_chapter_partial_one.txt")

  let assert Ok(updates) = parser.parse_updates_from_email(body)

  let assert [update] = updates
  assert expected == update
}

pub fn parse_updates_from_email_single_chapter_partial_two_test() {
  let expected =
    parser.NewChapter(
      parser.DetailedWork(
        789_141,
        "Some Nameless Work (Break things)(",
        "ArcOnyx and FakeUser",
        "3/?",
        "Glee - Unit Testing",
        "General",
        "Choose Not To Use Archive Warnings",
        None,
        None,
      ),
      1_414_155,
      "Chapter 3: Hi There (4072 words)",
      Some("This is a three\n\nline chapter summary"),
    )

  let assert Ok(body) =
    simplifile.read(data_path <> "email_body_single_chapter_partial_two.txt")

  let assert Ok(updates) = parser.parse_updates_from_email(body)

  let assert [update] = updates
  assert expected == update
}

pub fn parse_updates_from_email_single_chapter_partial_three_test() {
  let expected =
    parser.NewChapter(
      parser.DetailedWork(
        789_141,
        "Some Nameless Work (Break things)(",
        "ArcOnyx and FakeUser",
        "3/?",
        "Glee - Unit Testing",
        "General",
        "Choose Not To Use Archive Warnings",
        None,
        None,
      ),
      1_414_155,
      "Chapter 3: Hi There (4072 words)",
      Some("This is a three\n\nline chapter summary"),
    )

  let assert Ok(body) =
    simplifile.read(data_path <> "email_body_single_chapter_partial_three.txt")

  let assert Ok(updates) = parser.parse_updates_from_email(body)

  let assert [update] = updates
  assert expected == update
}

pub fn parse_updates_from_email_single_chapter_partial_four_test() {
  let expected =
    parser.NewChapter(
      parser.DetailedWork(
        789_141,
        "Some Nameless Work (Break things)(",
        "ArcOnyx and FakeUser",
        "3/?",
        "Glee - Unit Testing",
        "General",
        "Choose Not To Use Archive Warnings",
        None,
        None,
      ),
      1_414_155,
      "Chapter 3: Hi There (4072 words)",
      None,
    )

  let assert Ok(body) =
    simplifile.read(data_path <> "email_body_single_chapter_partial_four.txt")

  let assert Ok(updates) = parser.parse_updates_from_email(body)

  let assert [update] = updates
  assert expected == update
}

pub fn parse_updates_from_email_single_chapter_sparse_test() {
  let expected =
    parser.NewChapter(
      parser.SparseWork(789_141, "Some Nameless Work (Break things)("),
      1_414_155,
      "Chapter 3: Hi There (4072 words)",
      None,
    )

  let assert Ok(body) =
    simplifile.read(data_path <> "email_body_single_chapter_sparse.txt")

  let assert Ok(updates) = parser.parse_updates_from_email(body)

  let assert [update] = updates
  assert expected == update
}

pub fn parse_updates_from_email_single_chapter_sparse_two_test() {
  let expected =
    parser.NewChapter(
      parser.SparseWork(789_141, "Some Nameless Work (Break things)("),
      1_414_155,
      "Chapter 3: Hi There (4072 words)",
      Some("Some summary\nexists"),
    )

  let assert Ok(body) =
    simplifile.read(data_path <> "email_body_single_chapter_sparse_two.txt")

  let assert Ok(updates) = parser.parse_updates_from_email(body)

  let assert [update] = updates
  assert expected == update
}

pub fn parse_updates_from_email_multiple_test() {
  // We decompose it instead of using a list so errors only show the differing objecxts
  let expected1 =
    parser.NewChapter(
      parser.DetailedWork(
        11_111,
        "Test Work",
        "ArcOnyx",
        "2/2",
        "Glee - Unit Testing",
        "Teen And Up Audiences",
        "No Archive Warnings Apply",
        Some("Part 5 of ArcOnyx's test collection"),
        Some("This is a simple summary."),
      ),
      22_222,
      "Chapter 2: Chapter 1: Pineapples (4 words)",
      Some("Pineapples are tasty."),
    )
  let expected2 =
    parser.NewWork(parser.SparseWork(63_278_095, "Test Work (200 words)"))
  let expected3 =
    parser.NewChapter(
      parser.DetailedWork(
        333,
        "A Third Test",
        "ArcOnyx",
        "23/52",
        "Fancy fandom",
        "Mature",
        "Choose Not To Use Archive Warnings, Graphic Depictions Of Violence, Major Character Death",
        None,
        Some("Things are fine.\n\nWe hope."),
      ),
      34_567,
      "Chapter 3: Cats (55220 words)",
      None,
    )

  let assert Ok(body) = simplifile.read(data_path <> "email_body_multiple.txt")

  let assert Ok([update1, update2, update3]) =
    parser.parse_updates_from_email(body)
  assert expected1 == update1
  assert expected2 == update2
  assert expected3 == update3
}

pub fn parse_updates_from_email_new_work_test() {
  let expected =
    parser.NewWork(parser.DetailedWork(
      123_456,
      "Title (1013 words)",
      "ArcOnyx",
      "1/14",
      "Glee - Unit Testing",
      "Not Rated",
      "Choose Not To Use Archive Warnings",
      None,
      Some("Arbitary test summary."),
    ))

  let assert Ok(body) = simplifile.read(data_path <> "email_body_new_work.txt")

  let assert Ok(updates) = parser.parse_updates_from_email(body)

  let assert [update] = updates
  assert expected == update
}
