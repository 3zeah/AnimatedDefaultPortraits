use std::io;

use thiserror::Error;

use crate::constrained_reader::{ChunkReader, LeaveChunkError};
use crate::{ChunkParseError, Parse, ParseError, ParseResult, parse_error};

pub struct Parser<R: io::Read + io::Seek + ?Sized> {
    inner: ChunkReader<R>,
}

#[derive(Error, Debug)]
pub enum InitParserError {
    #[error(
        "reader position overflow: position is out of u32 range: {} (u32::MAX = {})",
        .0,
        u32::MAX
    )]
    PositionOverflow(u64),

    #[error("io error while reading stream position to init chunk reader: {0}")]
    FailedToReadStreamPosition(#[source] io::Error),
}

impl<R: io::Read + io::Seek> Parser<R> {
    pub fn new(inner: R, stream_position: u32) -> Result<Self, InitParserError> {
        let inner = ChunkReader::new(inner, stream_position)?;
        Ok(Self { inner })
    }
}

impl<R: io::Read + io::Seek> Parse for Parser<R> {
    fn offset_in_chunk(&self) -> u32 {
        self.inner.offset_in_chunk()
    }

    fn chunk(&self) -> Option<super::Chunk> {
        self.inner.chunk()
    }

    fn seek_in_chunk(&mut self, offset: u32) -> ParseResult<()> {
        Ok(self.inner.seek_in_chunk(offset)?)
    }

    fn skip(&mut self, len: u32) -> ParseResult<()> {
        self.inner.seek_relative(len.into())?;
        Ok(())
    }

    fn read_bytes<const N: usize>(&mut self) -> ParseResult<[u8; N]> {
        let mut buf = [0u8; N];
        self.inner.read_exact(&mut buf)?;
        Ok(buf)
    }

    fn read_bytes_or_eof<const N: usize>(&mut self) -> Option<ParseResult<[u8; N]>> {
        let mut buf = [0u8; N];
        let mut total_read = 0;
        while total_read < N {
            let size_read = match io::Read::read(&mut self.inner, &mut buf[total_read..]) {
                Ok(ok) => ok,
                Err(e) => return Some(Err(e.into())),
            };
            if size_read == 0 {
                break;
            }
            total_read += size_read;
        }
        if total_read == 0 {
            None
        } else if total_read < N {
            Some(Err(parse_error(
                "unexpected eof while reading chunk signature",
            )))
        } else {
            let as_array: [u8; N] = buf
                .try_into()
                .expect("illegal state: reader claimed enough bytes were read, but they were not");
            Some(Ok(as_array))
        }
    }

    fn read_byte_slice(&mut self, len: u32) -> ParseResult<Box<[u8]>> {
        let mut buf = vec![0u8; len as usize];
        self.inner.read_exact(&mut buf)?;
        Ok(buf.into_boxed_slice())
    }

    fn parse_chunk<Output, Format>(
        &mut self,
        size: u32,
        format: Format,
    ) -> Result<Output, ChunkParseError>
    where
        Format: Fn(&mut Self) -> ParseResult<Output>,
    {
        self.inner.enter_chunk(size)?;
        let output = format(self)?;
        self.seek_in_chunk(size)?; // ensure stream position after call is at end of chunk
        if let Some(err) = self.inner.leave_chunk().err() {
            match err {
                LeaveChunkError::NotInChunk => {
                    panic!("illegal state: system expected to be in a chunk, but was not");
                }
                LeaveChunkError::PositionOverflow(pos) => {
                    return Err(ChunkParseError::PositionOverflow(pos));
                }
            }
        }
        Ok(output)
    }
}

impl From<InitParserError> for ParseError {
    fn from(value: InitParserError) -> Self {
        match value {
            e @ InitParserError::PositionOverflow(_) => parse_error(e),
            e @ InitParserError::FailedToReadStreamPosition(_) => parse_error(e),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parser_to_test<Bytes: AsRef<[u8]>>(inner: Bytes) -> impl Parse {
        Parser::new(io::Cursor::new(inner), 0).expect("failed to create parser")
    }

    #[test]
    fn significant_happy_case() {
        // # DATA FORMAT
        // 10 magic bytes
        // 6 padding
        // repeating:
        // * u32 chunk size
        // * <chunk format>
        //
        // ## CHK1 FORMAT
        // 4 magic bytes
        // a: i32, b: u32, c: [i16] via ArrayHeader (len + offset)
        //
        // ## CHK2 FORMAT
        // 4 magic bytes
        // d: u32, 2 padding, e: u16
        let data = b"\
        FILE_MAGIC\0\0\0\0\0\0\
        \x20\x00\x00\x00CHK1\
        \x10\x20\x40\x80\x10\x20\x40\x80\
        \x05\x00\x00\x00\x10\x00\x00\x00\
        \xff\xff\xfe\xff\xfd\xff\xfc\xff\xfb\xff\
        \x00\x00\x00\x00\x00\x00\
        \x08\x00\x00\x00CHK2\
        \xce\x21\xbf\x12\xff\xff\xfe\xce\
        ";

        let mut parser = parser_to_test(data);

        let magic: [u8; 10] = parser.read_bytes().unwrap();
        assert_eq!(b"FILE_MAGIC", &magic);
        let padding: [u8; 6] = parser.read_bytes().unwrap();
        assert_eq!([0, 0, 0, 0, 0, 0], padding);

        let chunk_1_size = parser.parse_u32().unwrap();
        assert_eq!(32, chunk_1_size);
        let chunk_1_magic: [u8; 4] = parser.read_bytes().unwrap();
        assert_eq!(b"CHK1", &chunk_1_magic);
        fn parse_chk1<R: Parse>(r: &mut R) -> ParseResult<(i32, u32, Box<[i16]>)> {
            let a = r.parse_i32().unwrap();
            let b = r.parse_u32().unwrap();
            let c_header = r.parse_array_header().unwrap();
            let c = r
                .parse_array_from_header(c_header, Parse::parse_i16)
                .unwrap();
            r.expect_padding_until_chunk_end().unwrap();
            Ok((a, b, c))
        }
        let (a, b, c) = parser.parse_chunk(chunk_1_size, parse_chk1).unwrap();
        assert_eq!(-2143281136, a);
        assert_eq!(2151686160, b);
        assert_eq!([-1, -2, -3, -4, -5], *c);

        let chunk_2_size = parser.parse_u32().unwrap();
        assert_eq!(8, chunk_2_size);
        let chunk_2_magic: [u8; 4] = parser.read_bytes().unwrap();
        assert_eq!(b"CHK2", &chunk_2_magic);
        fn parse_chk2<R: Parse>(r: &mut R) -> ParseResult<(u32, i16)> {
            let d = r.parse_u32().unwrap();
            r.skip(2).unwrap();
            let e = r.parse_i16().unwrap();
            Ok((d, e))
        }
        let (d, e) = parser.parse_chunk(chunk_2_size, parse_chk2).unwrap();
        assert_eq!(314515918, d);
        assert_eq!(-12546, e);
    }

    mod primitive_parsing {
        use super::*;

        #[test]
        fn integers_are_little_endian() {
            let mut parser = parser_to_test(b"\x08\x04\x02\x01");
            assert_eq!(0x01020408, parser.parse_i32().unwrap());
        }

        #[test]
        fn can_parse_zero() {
            let expected = 0u32;
            let mut parser = parser_to_test(u32::to_le_bytes(expected));
            assert_eq!(expected, parser.parse_u32().unwrap());
        }

        #[test]
        fn can_parse_signed_integers() {
            let expected = 15915901;
            assert!(i32::is_positive(expected));
            let mut parser = parser_to_test(i32::to_le_bytes(expected));
            assert_eq!(expected, parser.parse_i32().unwrap());
        }

        #[test]
        fn can_parse_negative_integers() {
            let expected = -15915901;
            assert!(i32::is_negative(expected));
            let mut parser = parser_to_test(i32::to_le_bytes(expected));
            assert_eq!(expected, parser.parse_i32().unwrap());
        }

        #[test]
        fn can_parse_signed_zero() {
            let expected = 0i32;
            let mut parser = parser_to_test(i32::to_le_bytes(expected));
            assert_eq!(expected, parser.parse_i32().unwrap());
        }

        #[test]
        fn can_parse_floats() {
            let expected = 190510501.148919;
            assert!(f32::is_sign_positive(expected));
            let mut parser = parser_to_test(f32::to_le_bytes(expected));
            assert_eq!(expected, parser.parse_f32().unwrap());
        }

        #[test]
        fn can_parse_negative_floats() {
            let expected = -190510501.148919;
            assert!(f32::is_sign_negative(expected));
            let mut parser = parser_to_test(f32::to_le_bytes(expected));
            assert_eq!(expected, parser.parse_f32().unwrap());
        }

        #[test]
        fn can_parse_float_zero() {
            let expected = 0f32;
            let mut parser = parser_to_test(f32::to_le_bytes(expected));
            assert_eq!(expected, parser.parse_f32().unwrap());
        }

        #[test]
        fn single_byte_may_be_read() {
            let mut parser = parser_to_test(b"\x01\x02\x04\x08");
            assert_eq!(0x1, parser.parse_u8().unwrap());
        }
    }

    #[test]
    fn may_read_all_bytes() {
        let expected = b"\x01\x02\x04\x08";
        let mut parser = parser_to_test(expected);
        assert_eq!(expected, &parser.read_bytes().unwrap());
    }

    #[test]
    fn may_read_some_bytes() {
        let mut parser = parser_to_test(b"\x01\x02\x04\x08");
        let actual: [u8; 2] = parser.read_bytes().unwrap();
        assert_eq!(b"\x01\x02", &actual);
    }

    #[test]
    fn may_read_no_bytes() {
        let mut parser = parser_to_test(b"\x01\x02\x04\x08");
        let actual: [u8; 0] = parser.read_bytes().unwrap();
        assert_eq!(b"", &actual);
    }

    #[test]
    fn may_not_over_read() {
        let mut parser = parser_to_test(b"\x01\x02\x04\x08");
        let error = parser.read_bytes::<5>().unwrap_err();
        assert_eq!(
            "invalid data during parse: failed to fill whole buffer",
            error.to_string()
        );
    }

    mod seek_outside_chunk {
        use super::*;

        #[test]
        fn seeks_relative_to_stream_start() {
            let data = b"\x01\x02\x04\x08";
            let mut parser = parser_to_test(&data);
            parser.seek_in_chunk(2).unwrap();
            assert_eq!(data[2], parser.parse_u8().unwrap());
        }
    }

    mod read_in_chunk {
        use super::*;

        #[test]
        fn may_read_all_bytes_in_chunk() {
            const CHUNK_SIZE: usize = 3;
            let data = b"\x01\x02\x04\x08\x10\x20\x40\x80";
            let mut parser = parser_to_test(&data);
            parser.read_bytes::<2>().unwrap(); // skip 2
            let actual: [u8; CHUNK_SIZE] = parser
                .parse_chunk(CHUNK_SIZE as u32, Parse::read_bytes)
                .unwrap();
            assert_eq!(b"\x04\x08\x10", &actual);
        }

        #[test]
        fn may_read_no_bytes_in_chunk() {
            let data = b"\x01\x02\x04\x08\x10\x20\x40\x80";
            let mut parser = parser_to_test(&data);
            parser.read_bytes::<2>().unwrap(); // skip 2
            let actual: [u8; 0] = parser.parse_chunk(0, Parse::read_bytes).unwrap();
            assert_eq!(b"", &actual);
        }

        #[test]
        fn cannot_read_past_chunk_even_if_data_exists() {
            let data = b"\x01\x02\x04\x08\x10\x20\x40\x80";
            let mut parser = parser_to_test(&data);
            let actual: ChunkParseError = parser.parse_chunk(3, |p| p.parse_u32()).unwrap_err();
            assert_eq!(
                "error while parsing chunk: invalid data during parse: reader out of bounds: \
                offset in chunk was 4, but chunk range was [0, 3)",
                actual.to_string()
            );
        }

        #[test]
        fn cannot_read_past_chunk_even_if_read_is_smaller_than_size() {
            let data = b"\x01\x02\x04\x08\x10\x20\x40\x80";
            let mut parser = parser_to_test(&data);
            let error = parser
                .parse_chunk(3, |p| {
                    // this seek in isolation is ok
                    p.seek_in_chunk(2)?;
                    // this read in isolation is ok
                    p.parse_u16()
                })
                .unwrap_err();
            // but in combination, the read after seek is out of chunk
            assert_eq!(
                "error while parsing chunk: invalid data during parse: reader out of bounds: \
                offset in chunk was 4, but chunk range was [0, 3)",
                error.to_string()
            );
        }

        #[test]
        fn inner_parse_error_propagates() {
            let data = b"\x00\x00\x00\x00";
            let mut parser = parser_to_test(&data);
            let error = parser
                .parse_chunk::<(), _>(4, |r| {
                    r.expect_byte_array(&[1, 1])?; // this should fail
                    Err(parse_error("some other error"))
                })
                .unwrap_err();
            assert_eq!(
                "error while parsing chunk: invalid data during parse: read bytes did not match \
                expectation: expected [1, 1], but was [0, 0]",
                error.to_string()
            );
        }
    }

    mod seek_in_chunk {
        use super::*;

        #[test]
        fn seek_is_relative_to_start_of_chunk() {
            let data = b"\x01\x02\x04\x08\x10\x20\x40\x80";
            let mut parser = parser_to_test(&data);
            parser.read_bytes::<2>().unwrap(); // skip 2
            let actual = parser
                .parse_chunk(4, |p| {
                    p.seek_in_chunk(3).unwrap(); // skip 3 in chunk
                    p.parse_u8()
                })
                .unwrap();
            // expected skipped 5 total
            assert_eq!(data[5], actual);
        }

        #[test]
        fn cannot_seek_past_chunk_even_if_data_exists() {
            let data = b"\x01\x02\x04\x08\x10\x20\x40\x80";
            let mut parser = parser_to_test(&data);
            let error = parser.parse_chunk(3, |p| p.seek_in_chunk(4)).unwrap_err();
            assert_eq!(
                "error while parsing chunk: invalid data during parse: reader out of bounds: \
                offset in chunk was 4, but chunk range was [0, 3)",
                error.to_string()
            );
        }

        #[test]
        fn seek_is_relative_to_start_of_chunk_even_when_stream_position_is_not_at_start_of_chunk() {
            let data = b"\x01\x02\x04\x08\x10\x20\x40\x80";
            let mut parser = parser_to_test(&data);
            parser.read_bytes::<2>().unwrap(); // skip 2
            let actual = parser
                .parse_chunk(3, |p| {
                    p.parse_u16().unwrap();
                    // this seek is ok unless the seek is relative to current position (2 in chunk)
                    p.seek_in_chunk(2)
                })
                .unwrap();
            assert_eq!((), actual);
        }
    }
}
