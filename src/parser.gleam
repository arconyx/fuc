import gleam/bit_array
import gleam/dynamic/decode
import gleam/http/response.{type Response}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/regexp
import gleam/result
import gleam/string
import gleam/time/timestamp.{type Timestamp}

pub type Error {
  DecodeError(json.DecodeError)
  // TODO: Expand ParseError to also accept a List(String) so we can stop shoving
  // it onto the end of the string
  ParseError(String)
  BuilderError(String)
}

/// AO3 emails only include full details for a work once per email
/// For all successive works we can only get the title and id
/// We model this as a DetailedWork and a SparseWork
pub type Work {
  DetailedWork(
    id: Int,
    title: String,
    authors: String,
    chapters: String,
    fandom: String,
    rating: String,
    warnings: String,
    // relationships: Option(String),
    // character: Option(String),
    // additional_tags: Option(String),
    series: Option(String),
    summary: Option(String),
  )
  SparseWork(id: Int, title: String)
}

pub type ArchiveUpdate {
  NewWork(work: Work)
  NewChapter(
    work: Work,
    // authors: String,
    chapter_id: Int,
    chapter_title: String,
    chapter_summary: Option(String),
  )
}

type UpdateType {
  IsNewWork
  IsNewChapter
}

// type WorkType {
//   IsSparseWork
//   IsDetailedWork
// }

type UpdateBuilder {
  WorkUpdateBuilder(
    work_id: Option(Int),
    work_title: Option(String),
    // is_sparse_work: Option(WorkType),
    authors: Option(String),
    chapters: Option(String),
    fandom: Option(String),
    rating: Option(String),
    warnings: Option(String),
    series: Option(String),
    work_summary: Option(String),
    update_type: UpdateType,
  )
  ChapterUpdateBuilder(
    work_id: Option(Int),
    work_title: Option(String),
    // is_sparse_work: Option(WorkType),
    authors: Option(String),
    chapters: Option(String),
    fandom: Option(String),
    rating: Option(String),
    warnings: Option(String),
    series: Option(String),
    work_summary: Option(String),
    update_type: UpdateType,
    chapter_id: Option(Int),
    chapter_title: Option(String),
    chapter_summary: Option(String),
  )
}

fn new_work_update() -> UpdateBuilder {
  WorkUpdateBuilder(
    None,
    None,
    None,
    None,
    None,
    None,
    None,
    None,
    None,
    IsNewWork,
  )
}

fn new_chapter_update() -> UpdateBuilder {
  ChapterUpdateBuilder(
    None,
    None,
    None,
    None,
    None,
    None,
    None,
    None,
    None,
    IsNewChapter,
    None,
    None,
    None,
  )
}

fn set_work_id(builder: UpdateBuilder, id: Int) -> UpdateBuilder {
  case builder {
    WorkUpdateBuilder(..) -> WorkUpdateBuilder(..builder, work_id: Some(id))
    ChapterUpdateBuilder(..) ->
      ChapterUpdateBuilder(..builder, work_id: Some(id))
  }
}

fn set_work_title(
  builder: UpdateBuilder,
  title: String,
) -> Result(UpdateBuilder, Error) {
  case builder, title {
    _, "" -> BuilderError("Empty work title") |> Error
    WorkUpdateBuilder(..), _ ->
      WorkUpdateBuilder(..builder, work_title: Some(title)) |> Ok
    ChapterUpdateBuilder(..), _ ->
      ChapterUpdateBuilder(..builder, work_title: Some(title)) |> Ok
  }
}

fn set_chapter_id(
  builder: UpdateBuilder,
  id: Int,
) -> Result(UpdateBuilder, Error) {
  case builder {
    WorkUpdateBuilder(..) ->
      BuilderError("Can't set chapter id of work") |> Error
    ChapterUpdateBuilder(..) ->
      ChapterUpdateBuilder(..builder, chapter_id: Some(id)) |> Ok
  }
}

fn set_chapter_title(
  builder: UpdateBuilder,
  title: String,
) -> Result(UpdateBuilder, Error) {
  case builder, title {
    WorkUpdateBuilder(..), _ ->
      BuilderError("Can't set chapter title of work") |> Error
    ChapterUpdateBuilder(..), "" -> BuilderError("Empty chapter title") |> Error
    ChapterUpdateBuilder(..), _ ->
      ChapterUpdateBuilder(..builder, chapter_title: Some(title)) |> Ok
  }
}

fn set_authors(
  builder: UpdateBuilder,
  authors: String,
) -> Result(UpdateBuilder, Error) {
  case builder, authors {
    _, "" -> BuilderError("Empty authors") |> Error
    WorkUpdateBuilder(..), _ ->
      WorkUpdateBuilder(..builder, authors: Some(authors)) |> Ok
    ChapterUpdateBuilder(..), _ ->
      ChapterUpdateBuilder(..builder, authors: Some(authors)) |> Ok
  }
}

fn set_chapter_summary(
  builder: UpdateBuilder,
  summary: String,
) -> Result(UpdateBuilder, Error) {
  case builder, summary {
    WorkUpdateBuilder(..), _ ->
      BuilderError("Can't set chapter summary of work") |> Error
    ChapterUpdateBuilder(..), "" ->
      BuilderError("Empty chapter summary") |> Error
    ChapterUpdateBuilder(..), _ ->
      ChapterUpdateBuilder(..builder, chapter_summary: Some(summary)) |> Ok
  }
}

fn set_details(
  builder: UpdateBuilder,
  chapters: String,
  fandom: String,
  rating: String,
  warnings: String,
) -> Result(UpdateBuilder, Error) {
  let inputs = [chapters, fandom, rating, warnings]
  case list.any(inputs, string.is_empty) {
    True -> BuilderError("Empty string in work details") |> Error
    False -> {
      case builder {
        WorkUpdateBuilder(..) ->
          WorkUpdateBuilder(
            ..builder,
            chapters: Some(chapters),
            fandom: Some(fandom),
            rating: Some(rating),
            warnings: Some(warnings),
          )
          |> Ok
        ChapterUpdateBuilder(..) ->
          ChapterUpdateBuilder(
            ..builder,
            chapters: Some(chapters),
            fandom: Some(fandom),
            rating: Some(rating),
            warnings: Some(warnings),
          )
          |> Ok
      }
    }
  }
}

fn set_series(
  builder: UpdateBuilder,
  series: String,
) -> Result(UpdateBuilder, Error) {
  case builder, series {
    _, "" -> BuilderError("Empty series") |> Error
    WorkUpdateBuilder(..), _ ->
      WorkUpdateBuilder(..builder, series: Some(series)) |> Ok
    ChapterUpdateBuilder(..), _ ->
      ChapterUpdateBuilder(..builder, series: Some(series)) |> Ok
  }
}

fn set_work_summary(
  builder: UpdateBuilder,
  summary: String,
) -> Result(UpdateBuilder, Error) {
  case builder, summary {
    _, "" -> BuilderError("Empty work summary") |> Error
    WorkUpdateBuilder(..), _ ->
      WorkUpdateBuilder(..builder, work_summary: Some(summary)) |> Ok
    ChapterUpdateBuilder(..), _ ->
      ChapterUpdateBuilder(..builder, work_summary: Some(summary)) |> Ok
  }
}

fn to_update(builder: UpdateBuilder) -> Result(ArchiveUpdate, Error) {
  case builder {
    // Sparse work + new work
    WorkUpdateBuilder(
      Some(work_id),
      Some(work_title),
      None,
      None,
      None,
      None,
      None,
      None,
      None,
      IsNewWork,
    ) -> SparseWork(work_id, work_title) |> NewWork |> Ok
    // Detailed work + new work
    WorkUpdateBuilder(
      Some(work_id),
      Some(work_title),
      Some(authors),
      Some(chapters),
      Some(fandom),
      Some(rating),
      Some(warnings),
      series,
      summary,
      IsNewWork,
    ) ->
      DetailedWork(
        work_id,
        work_title,
        authors,
        chapters,
        fandom,
        rating,
        warnings,
        series,
        summary,
      )
      |> NewWork
      |> Ok
    // Sparse work + new chapter
    ChapterUpdateBuilder(
      Some(work_id),
      Some(work_title),
      None,
      None,
      None,
      None,
      None,
      None,
      None,
      IsNewChapter,
      Some(chapter_id),
      Some(chapter_title),
      chapter_summary,
    ) ->
      SparseWork(work_id, work_title)
      |> NewChapter(chapter_id, chapter_title, chapter_summary)
      |> Ok
    // Detaileld work + new chapter
    ChapterUpdateBuilder(
      Some(work_id),
      Some(work_title),
      Some(authors),
      Some(chapters),
      Some(fandom),
      Some(rating),
      Some(warnings),
      series,
      work_summary,
      IsNewChapter,
      Some(chapter_id),
      Some(chapter_title),
      chapter_summary,
    ) ->
      DetailedWork(
        work_id,
        work_title,
        authors,
        chapters,
        fandom,
        rating,
        warnings,
        series,
        work_summary,
      )
      |> NewChapter(chapter_id, chapter_title, chapter_summary)
      |> Ok
    _ ->
      ParseError("Invalid builder state:\n" <> string.inspect(builder)) |> Error
  }
}

const archive_email_header = "========================================="

fn strip_header(s: String) -> Result(String, Error) {
  case string.split_once(s, archive_email_header) {
    Ok(#(_, trimmed)) -> string.trim_start(trimmed) |> Ok
    Error(Nil) -> Error(ParseError("Header not found. Email: \n" <> s))
  }
}

const archive_email_footer_divider = "-----------------------------------------"

fn strip_footer(s: String) -> Result(String, Error) {
  case string.split_once(s, archive_email_footer_divider) {
    Ok(#(trimmed, _)) -> Ok(trimmed)
    Error(_) -> Error(ParseError("Footer not found"))
  }
}

fn split_lines(s: String) -> Result(List(String), Error) {
  case string.split(s, "\n") {
    [] -> Error(ParseError("No lines found"))
    [_] -> Error(ParseError("Single line found"))
    lines -> Ok(lines)
  }
}

/// Parse an API response containing an json object describing an email
///
/// Returns a list of updates in the email and the time the email was recieved
/// by the mailserver.
pub fn parse_email(
  email: Response(String),
) -> Result(#(List(ArchiveUpdate), Timestamp), Error) {
  let part_decoder = {
    use mime <- decode.field("mimeType", decode.string)
    case mime {
      "text/plain" -> {
        use data <- decode.subfield(["body", "data"], decode.string)
        let decoded =
          data
          |> bit_array.base64_url_decode
          |> result.try(fn(t) { bit_array.to_string(t) })
        case decoded {
          Ok(txt) -> decode.success(txt)
          Error(Nil) -> {
            decode.failure("body.data", "Base64 decoding body.data")
          }
        }
      }
      _ -> decode.failure("mimeType", "mimeType was " <> mime)
    }
  }

  let decoder = {
    use epoch_ms <- decode.field("internalDate", decode.string)
    use body <- decode.subfield(
      ["payload", "parts"],
      decode.at([0], part_decoder),
    )
    case int.parse(epoch_ms) {
      Ok(ms) -> {
        let time = ms / 1000 |> timestamp.from_unix_seconds()
        #(body, time) |> decode.success
      }
      Error(_) ->
        #("", timestamp.from_unix_seconds(0)) |> decode.failure("internalDate")
    }
  }

  let email =
    json.parse(email.body, decoder)
    |> result.map_error(fn(e) { DecodeError(e) })

  case email {
    Ok(#(body, time)) -> {
      case parse_updates_from_email(body) {
        Ok(updates) -> #(updates, time) |> Ok
        Error(e) -> Error(e)
      }
    }
    Error(e) -> Error(e)
  }
}

// TODO: Start by breaking on divider?
const archive_email_update_divider = "\n--------------------\n"

pub fn parse_updates_from_email(
  body: String,
) -> Result(List(ArchiveUpdate), Error) {
  // Normalise line endings
  let body = string.replace(body, "\r\r\n", "\n")
  let body = string.replace(body, "\r\n", "\n")

  use body <- result.try(body |> strip_header)
  use body <- result.try(body |> strip_footer)

  // Split and parse updates
  // try_map will abort all processing if any fails
  string.split(body, archive_email_update_divider)
  |> list.try_map(parse_update)
}

fn parse_update(blob: String) -> Result(ArchiveUpdate, Error) {
  use lines <- result.try(blob |> string.trim |> split_lines)

  case lines {
    [title_line, ..rest] -> {
      case string.crop(title_line, "posted a") {
        "posted a new work:" | "posted a backdated work:" ->
          parse_update_work(rest)
        "posted a new chapter of " <> title_and_len -> {
          case regexp.from_string(" \\(\\d+ words\\):\\Z") {
            Ok(re) -> {
              let title = regexp.replace(re, title_and_len, "")
              parse_update_chapter(rest, title)
            }
            Error(_) ->
              Error(ParseError("Unable to construct word count regex"))
          }
        }
        line ->
          Error(ParseError(
            "Unable to parse title from: "
            <> line
            <> "\nIn email:\n"
            <> string.join(lines, with: "\n"),
          ))
      }
    }
    [] -> Error(ParseError("Empty list when seeking title"))
  }
}

// Expects the first line to be the chapter url
fn parse_update_chapter(
  lines: List(String),
  work_title: String,
) -> Result(ArchiveUpdate, Error) {
  let builder = {
    let builder = new_chapter_update() |> set_work_title(work_title)
    use builder <- result.try(builder)
    use builder, lines <- extract_chapter_url(builder, lines)
    use builder, lines <- extract_chapter_title(builder, lines)
    use builder, lines <- extract_authors(builder, lines)
    use builder, lines <- extract_chapter_summary(builder, lines)
    use builder, lines <- extract_details(builder, lines)
    extract_work_summary(builder, lines)
  }
  use builder <- result.try(builder)
  builder |> to_update
}

fn parse_update_work(lines: List(String)) {
  let builder = {
    let builder = new_work_update()
    use builder, lines <- extract_work_url(builder, lines)
    use builder, lines <- extract_work_title(builder, lines)
    use builder, lines <- extract_authors(builder, lines)
    use builder, lines <- extract_details(builder, lines)
    extract_work_summary(builder, lines)
  }
  use builder <- result.try(builder)
  builder |> to_update
}

/// Extracts chapter and work id from chapter url
/// 
/// The first line is expected to be an AO3 chapter URL.
/// The second line is expected to be blank.
/// e.g.
/// ```
/// https://archiveofourown.org/works/12345/chapters/6789
///
/// ...
/// ```
/// Work and chapter ids are extracted from this url and applied to the builder.
///
/// Calls the next function with the url and blank line removed from the lines list.
/// We expect that this makes the new leading line the title line (see `extract_title`).
fn extract_chapter_url(
  builder: UpdateBuilder,
  lines: List(String),
  next: fn(UpdateBuilder, List(String)) -> Result(UpdateBuilder, Error),
) -> Result(UpdateBuilder, Error) {
  case lines {
    ["http://archiveofourown.org/works/" <> url, "", ..rest]
    | ["https://archiveofourown.org/works/" <> url, "", ..rest] -> {
      case string.split(url, "/") {
        [work_id, "chapters", chapter_id] -> {
          case int.parse(work_id), int.parse(chapter_id) {
            Ok(work_id), Ok(chapter_id) ->
              builder
              |> set_work_id(work_id)
              |> set_chapter_id(chapter_id)
              |> result.try(fn(b) { next(b, rest) })
            _, _ ->
              ParseError(
                "Unable to parse ids from " <> work_id <> " or " <> chapter_id,
              )
              |> Error
          }
        }
        parts ->
          ParseError("Invalid url parts: " <> string.inspect(parts)) |> Error
      }
    }
    _ ->
      ParseError(
        "Invalid list when seeking url:\n" <> string.join(lines, with: "\n"),
      )
      |> Error
  }
}

/// Extracts chapter and work id from work url
/// 
/// The first line is expected to be an AO3 work URL.
/// The second line is expected to be blank.
/// e.g.
/// ```
/// https://archiveofourown.org/works/12345
///
/// ...
/// ```
/// The work id is extracted from this url and applied to the builder.
///
/// Calls the next function with the url and blank line removed from the lines list.
/// We expect that this makes the new leading line the title line (see `extract_title`).
fn extract_work_url(
  builder: UpdateBuilder,
  lines: List(String),
  next: fn(UpdateBuilder, List(String)) -> Result(UpdateBuilder, Error),
) -> Result(UpdateBuilder, Error) {
  case lines {
    ["http://archiveofourown.org/works/" <> work_id, "", ..rest]
    | ["https://archiveofourown.org/works/" <> work_id, "", ..rest] -> {
      case int.parse(work_id) {
        Ok(work_id) ->
          builder
          |> set_work_id(work_id)
          |> next(rest)
        Error(_) ->
          ParseError("Unable to parse work id from " <> work_id)
          |> Error
      }
    }
    _ -> ParseError("Invalid list when seeking url") |> Error
  }
}

/// Extracts chapter title
/// 
/// The first line is expected to contain the chapter title
/// e.g `Chapter 2: Some Title (123 words)`
/// 
/// The only validation is asserting that it is non-empty.
/// We do not strip the word count from the title since it seems useful.
///
/// We only strip the title line from the list passed to the
/// next function.
/// We expect that the next line is the author line followed by a blank line,
/// or just the blank line (byline is only for detailed works).
/// See `extract_authors`.
fn extract_chapter_title(
  builder: UpdateBuilder,
  lines: List(String),
  next: fn(UpdateBuilder, List(String)) -> Result(UpdateBuilder, Error),
) -> Result(UpdateBuilder, Error) {
  case lines {
    ["", ..] -> ParseError("Couldn't find title") |> Error
    [chapter_title, ..rest] ->
      set_chapter_title(builder, chapter_title)
      |> result.try(fn(b) { next(b, rest) })
    _ -> ParseError("Invalid list when seeking title") |> Error
  }
}

/// Extracts chapter title
/// 
/// The first line is expected to contain the chapter title
/// e.g `Chapter 2: Some Title (123 words)`
/// 
/// The only validation is asserting that it is non-empty.
/// We do not strip the word count from the title since it seems useful.
///
/// We only strip the title line from the list passed to the
/// next function.
/// We expect that the next line is the author line followed by a blank line,
/// or just the blank line (byline is only for detailed works).
/// See `extract_authors`.
fn extract_work_title(
  builder: UpdateBuilder,
  lines: List(String),
  next: fn(UpdateBuilder, List(String)) -> Result(UpdateBuilder, Error),
) -> Result(UpdateBuilder, Error) {
  case lines {
    ["", ..] -> ParseError("Couldn't find title") |> Error
    [title, ..rest] ->
      set_work_title(builder, title)
      |> result.try(fn(b) { next(b, rest) })
    _ -> ParseError("Invalid list when seeking title") |> Error
  }
}

/// Extracts authors, if present
///
/// We expect one of the following line sequences
/// - `["by Name (profile url), Name2 (url) and Name3 (url)", "", ..]` for a detailed work
/// - `["", ..]` for a sparse work with chapter summary
/// - `[]` for a sparse work without chapter summary
/// as the author line only appears the first time a work appears in a single email.
///
/// We strip out profile urls and apply the plaintext author names to the builder
/// as a single string.
///
/// The byline, if present, and the following empty line are stripped from the list
/// passed to the next function.
/// The new leading lines are expected to be an optional chapter summary followed by
/// a blank line.
fn extract_authors(
  builder: UpdateBuilder,
  lines: List(String),
  next: fn(UpdateBuilder, List(String)) -> Result(UpdateBuilder, Error),
) -> Result(UpdateBuilder, Error) {
  case lines {
    ["by " <> authors, "", ..rest] ->
      case
        regexp.from_string(
          "\\Q (http\\Es?\\Q://archiveofourown.org/users/\\E\\S+\\)",
        )
      {
        Ok(re) ->
          regexp.replace(re, authors, "")
          |> set_authors(builder, _)
          |> result.try(fn(b) { next(b, rest) })
        Error(_) -> ParseError("Unable to construct author regex") |> Error
      }
    ["", ..rest] -> next(builder, rest)
    [first, ..] ->
      ParseError("Unable to extract authors from line: " <> first) |> Error
    // If the list is blank we're at the end
    [] -> builder |> Ok
  }
}

/// Extracts chapter summary, if present
///
/// We expect an optional line starting with 'Chapter Summary: '
/// followed by an unknown amount of summary lines, which may be blank,
/// or absent followed by a single blank line at the end.
///
/// This necessitates some recursion into the list.
fn extract_chapter_summary(
  builder: UpdateBuilder,
  lines: List(String),
  next: fn(UpdateBuilder, List(String)) -> Result(UpdateBuilder, Error),
) -> Result(UpdateBuilder, Error) {
  case lines {
    ["Chapter Summary: " <> summary_start, ..rest] -> {
      // We have a chapter summary split across an unknown number of lines
      // followed by a blank line.
      // But we can have blank lines in the summary.
      // Eek.
      // We need to find the chapter summary, if it exists
      // And we need to call the next function with only the summary
      // and the single trailing blank line removed.
      let lines = [summary_start, ..rest]
      let index = trawl_for_chapter_summary(lines, 0)
      let #(summary_lines, rest) = list.split(lines, index)
      string.join(summary_lines, "\n")
      |> string.trim
      |> set_chapter_summary(builder, _)
      |> result.try(fn(b) { next(b, rest) })
    }
    // If we don't have a chapter summary we can just erase the trailing newline
    ["", ..rest] -> next(builder, rest)
    [first, ..] ->
      ParseError("Unexpected line when seeking chapter summary: " <> first)
      |> Error
    // Empty lists should have been handled cleanly at `extract_author`
    // So if it occurs now something is wrong
    // At least one of the chapter summary or the work details should be present
    // If we're in this function
    // But we probably don't need to error
    // [] -> ParseError("Empty list when seeking chapter summary") |> Error
    [] -> builder |> Ok
  }
}

/// Search through the lines until we find the end of the chapter summary
///
/// This function is recursive. `index` should be zero for the inital
/// invocation.
///
/// # End points:
/// - End of list (there will be no trailing blank line because we trim trailing whitespace)
/// - String starting with `"Chapters: "`
///
/// Returns the index of the last line in the summary
fn trawl_for_chapter_summary(lines: List(String), index: Int) -> Int {
  case lines {
    // We don't worry about trimming the blank line before 'Chapters'
    [] | ["Chapters: " <> _, ..] -> index
    [_, ..rest] -> trawl_for_chapter_summary(rest, index + 1)
  }
}

/// Extract detailed work information from lines
///
/// This block is optional. If present the first line starts with `"Chapters: "`
/// and the block is trailed by a blank line.
/// There are several optional lines in the middle for various tags
///
/// The next function gets passed the lines without the work details.
/// There may be a leading newline before the summary begins
fn extract_details(
  builder: UpdateBuilder,
  lines: List(String),
  next: fn(UpdateBuilder, List(String)) -> Result(UpdateBuilder, Error),
) -> Result(UpdateBuilder, Error) {
  let lines = drop_empty_leading_lines(lines)
  case lines {
    [
      "Chapters: " <> chapters,
      "Fandom: " <> fandom,
      "Rating: " <> rating,
      "Warnings: " <> warnings,
      ..rest
    ]
    | [
        "Chapters: " <> chapters,
        "Fandom: " <> fandom,
        "Rating: " <> rating,
        "Warning: " <> warnings,
        ..rest
      ]
    | [
        "Chapters: " <> chapters,
        "Fandoms: " <> fandom,
        "Rating: " <> rating,
        "Warning: " <> warnings,
        ..rest
      ] -> {
      let builder = set_details(builder, chapters, fandom, rating, warnings)
      use builder <- result.try(builder)
      case rest {
        ["Series: " <> series, ..rest]
        | [_, "Series: " <> series, ..rest]
        | [_, _, "Series: " <> series, ..rest]
        | [_, _, _, "Series: " <> series, ..rest] ->
          builder
          |> set_series(series)
          |> result.try(fn(b) {
            // Strip leading empty line, if present
            let rest = case rest {
              ["", ..rest] -> rest
              _ -> rest
            }
            next(b, rest)
          })
        // Strip off optional tag lines if we don't have a series but do have a summary
        ["Summary:", ..rest]
        | [_, "Summary:", ..rest]
        | [_, _, "Summary:", ..rest]
        | [_, _, _, "Summary:", ..rest]
        | [_, _, _, _, "Summary:", ..rest]
        | [_, _, _, _, _, "Summary:", ..rest]
        | [_, _, _, _, _, _, "Summary:", ..rest] ->
          next(builder, ["Summary:", ..rest])
        // If we don't have an empty line in the first for then we can't havea
        // a summary, so we can just terminate.
        [_, ..] -> builder |> Ok
        [] -> builder |> Ok
      }
    }
    // If we have an empty list then we're probably at the end of an update with
    // a sparse work
    [] -> builder |> Ok
    _ ->
      ParseError(
        "Invalid work details found:\n" <> string.join(lines, with: "\n"),
      )
      |> Error
  }
}

/// Extract work summary, if present
///
/// This looks for a line starting with `"Summary: "`, possibly preceeded by a single
/// blank line.
///
/// This updates the builder with the work summary, then calls the next function
/// with the summary removed. We expect the summary to be the last thing in the list
/// and greedily consume the entire list.
fn extract_work_summary(
  builder: UpdateBuilder,
  lines: List(String),
) -> Result(UpdateBuilder, Error) {
  case drop_empty_leading_lines(lines) {
    // The actual summary always starts on the line after the header, with 4 space indention
    ["Summary:", "    " <> summary, ..more_summary] -> {
      string.join([summary, ..more_summary], "\n")
      |> string.trim
      |> set_work_summary(builder, _)
    }
    // Empty list, no summary, all good
    [] -> builder |> Ok
    _ ->
      ParseError("Invalid work summary:\n" <> string.join(lines, with: "\n"))
      |> Error
  }
}

fn drop_empty_leading_lines(lines: List(String)) -> List(String) {
  case lines {
    ["", ..rest] -> drop_empty_leading_lines(rest)
    _ -> lines
  }
}
