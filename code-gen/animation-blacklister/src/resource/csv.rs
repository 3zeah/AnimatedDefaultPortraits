use std::io::{self, BufRead, Read};
use std::{error, fmt};

#[derive(Debug)]
pub enum CsvParseError {
    EmptyFile(),
    UnexpectedHeader {
        expected: Vec<String>,
        actual: Vec<String>,
    },
    InvalidFormat {
        line_number: usize,
        header: Option<String>,
        expected_parts: usize,
        actual: String,
        actual_parts: usize,
    },
    ColumnFilterOutOfRange {
        actual: usize,
        max: usize,
    },
    IoError(io::Error),
}

/// parse a csv from the given reader, either requiring that the header is exactly as specified, or
/// requiring that the column count is `N` (the const generic). if the header is not specified, the
/// actual header will be the first element of the result
///
/// to parse only a subset of columns, use [parse_csv_filtered]
pub fn parse_csv<R: Read, const N: usize>(
    r: R,
    delim: &str,
    expected_format: Option<&[&str; N]>,
) -> Result<Vec<[String; N]>, CsvParseError> {
    parse::<R, N, N>(r, delim, expected_format, None)
}

/// parse a csv from the given reader, either requiring that the header is exactly as specified, or
/// requiring that the column count is `N` (the const generic), and returning the columns as
/// specified by `column_filter`. if the header is not specified, the actual header will be the
/// first element of the result
///
/// `column_filter` is defined as a sequence of 0-based indices corresponding to the index of the
/// column. eg, if `column_filter == [2, 0]`, the result will comprise rows containing the 3:rd and
/// 1:st element, in that order, from the source data. accordingly, each index in `column_filter`
/// must be less than the source column count
///
/// to parse all columns, use [parse_csv]
pub fn parse_csv_filtered<R: Read, const N: usize, const M: usize>(
    r: R,
    delim: &str,
    expected_format: Option<&[&str; N]>,
    column_filter: &[usize; M],
) -> Result<Vec<[String; M]>, CsvParseError> {
    parse(r, delim, expected_format, Some(column_filter))
}

/// keep private: if `column_filter` == `None`, then it must be the case that `N` == `M`: enforce
/// this with public wrappers
fn parse<R: Read, const N: usize, const M: usize>(
    r: R,
    delim: &str,
    expected_format: Option<&[&str; N]>,
    column_filter: Option<&[usize; M]>,
) -> Result<Vec<[String; M]>, CsvParseError> {
    let mut line_iterator = io::BufReader::new(r).lines().into_iter();
    // parse header
    let maybe_header = line_iterator.next();
    let header = match maybe_header {
        Some(line) => line?,
        None => return Err(CsvParseError::EmptyFile()),
    };
    if header.is_empty() {
        return Err(CsvParseError::EmptyFile());
    }
    let header_parts: Vec<&str> = header.split(delim).collect();
    // validate header
    if let Some(expected_format) = expected_format {
        if expected_format.len() != header_parts.len() {
            let expected_vec: Vec<String> = expected_format.iter().map(|s| s.to_string()).collect();
            let actual_vec: Vec<String> = header_parts.into_iter().map(str::to_owned).collect();
            return Err(CsvParseError::UnexpectedHeader {
                expected: expected_vec,
                actual: actual_vec,
            });
        }
        for i in 0..expected_format.len() {
            if expected_format[i] != header_parts[i] {
                let expected_vec: Vec<String> =
                    expected_format.iter().map(|s| s.to_string()).collect();
                let actual_vec: Vec<String> = header_parts.into_iter().map(str::to_owned).collect();
                return Err(CsvParseError::UnexpectedHeader {
                    expected: expected_vec,
                    actual: actual_vec,
                });
            }
        }
    } else if header_parts.len() != N {
        return Err(CsvParseError::InvalidFormat {
            line_number: 0,
            header: None,
            expected_parts: N,
            actual: header.clone(),
            actual_parts: header_parts.len(),
        });
    }
    let mut result: Vec<[String; M]> = Vec::new();
    // include header in result, if header was not specified
    if expected_format.is_none() {
        let result_row =
            parse_row::<N, M>(delim, &header, &header_parts, column_filter, 0, &header)?;
        result.push(result_row);
    }
    // parse data rows
    let mut line_number: usize = 1;
    for line_result in line_iterator {
        let row = line_result?;
        let result_row = parse_row::<N, M>(
            delim,
            &header,
            &header_parts,
            column_filter,
            line_number,
            &row,
        )?;
        result.push(result_row);
        line_number += 1;
    }
    Ok(result)
}

fn parse_row<const N: usize, const M: usize>(
    delim: &str,
    header: &String,
    header_parts: &Vec<&str>,
    column_filter: Option<&[usize; M]>,
    line_number: usize,
    row: &String,
) -> Result<[String; M], CsvParseError> {
    let row_parts: Vec<&str> = row.split(delim).collect();
    if row_parts.len() != N {
        return Err(CsvParseError::InvalidFormat {
            line_number,
            header: Some(header.clone()),
            expected_parts: header_parts.len(),
            actual: row.clone(),
            actual_parts: row_parts.len(),
        });
    }
    let row_parts_filtered: Vec<String> = if let Some(column_filter) = column_filter {
        let mut filtered = Vec::new();
        for filter_i in column_filter {
            let part = row_parts.get(*filter_i);
            if let Some(part) = part {
                filtered.push(part.to_string());
            } else {
                return Err(CsvParseError::ColumnFilterOutOfRange {
                    actual: *filter_i,
                    max: row_parts.len(),
                });
            };
        }
        filtered
    } else {
        row_parts.into_iter().map(str::to_owned).collect()
    };
    let result_row: [String; M] = row_parts_filtered.try_into().unwrap_or_else(|_| {
        // this is an internal error
        //
        // if `column_filter.is_some()`, `row_parts_filtered.len()` ==  `M`, because
        // `row_parts_filtered` is constructed from `column_filter`
        //
        // otherwise, if `column_filter == None`, it is required that `M == N` for this to work,
        // but this is not enforced by this method, and should be enforced by the public
        // wrappers
        panic!(
            "failed to force row parts into slice of size: const params are probably invalid (M = {}, N = {})",
            M, N
        )
    });
    Ok(result_row)
}

impl error::Error for CsvParseError {
    fn source(&self) -> Option<&(dyn error::Error + 'static)> {
        match self {
            CsvParseError::EmptyFile() => None,
            CsvParseError::UnexpectedHeader { .. } => None,
            CsvParseError::InvalidFormat { .. } => None,
            CsvParseError::ColumnFilterOutOfRange { .. } => None,
            CsvParseError::IoError(e) => Some(e),
        }
    }
}

impl fmt::Display for CsvParseError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            CsvParseError::EmptyFile() => write!(f, "file was empty"),
            CsvParseError::UnexpectedHeader { expected, actual } => {
                write!(
                    f,
                    r#"header did not match provided expectation: expected {:?}; actual {:?}"#,
                    expected, actual
                )
            }
            CsvParseError::InvalidFormat {
                line_number,
                header,
                expected_parts,
                actual: row,
                actual_parts: row_parts,
            } => {
                let header_string = header
                    .as_ref()
                    .map(|h| format!(r#" (header was "{}")"#, h))
                    .unwrap_or("".to_string());
                write!(
                    f,
                    r#"invalid row at line {}: expected {} parts{}, but row had {} ("{}")"#,
                    line_number, expected_parts, header_string, row_parts, row
                )
            }
            CsvParseError::ColumnFilterOutOfRange { actual, max } => write!(
                f,
                "column filter index out of range: was {}, but column count was {}",
                actual, max
            ),
            CsvParseError::IoError(e) => write!(f, "io error from provided reader: {}", e),
        }
    }
}

impl From<io::Error> for CsvParseError {
    fn from(value: io::Error) -> Self {
        CsvParseError::IoError(value)
    }
}
