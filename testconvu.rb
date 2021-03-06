#!/usr/local/bin/ruby -Ke
# testconvu.rb
# Copyright (C) 2004-2006  K.Kosako (sndgk393 AT ybb DOT ne DOT jp)

require 'iconv'

WINDOWS = (ARGV.size > 0 && /^-win/i =~ ARGV[0])
ARGV.shift if WINDOWS

BIG_ENDIAN    = 1
LITTLE_ENDIAN = 2

ICV_BE = Iconv.new('UTF-16BE', 'EUC-JP')
ICV_LE = Iconv.new('UTF-16LE', 'EUC-JP')

def eucjp_char_pos(s, byte_pos)
  pos = 0
  i   = 0
  while (i < byte_pos)
    x = s[i]
    if ((x >= 0xa1 && x <= 0xfe) || x == 0x8e)
      i += 2
    elsif (x == 0x8f)
      i += 3
    else
      i += 1
    end
    pos += 1
  end
  return pos
end

def utf16_byte_pos(endian, s, char_pos)
  i = 0
  while (char_pos > 0)
    x = (endian == BIG_ENDIAN ? s[i] : s[i+1])
    if (x >= 0xd8 && x <= 0xdb)
      i += 4
    else
      i += 2
    end
    char_pos -= 1
  end
  return i
end

def s_escape(s)
  q = ''
  s.each_byte { |b|
    if (b < 0x20 || b >= 0x7f || b == 0x22 || b == 0x5c)
      q << sprintf("\\%03o", b)
    else
      q << b.chr
    end
  }
  q
end

def conv_to_utf16(endian, s)
  begin
    if (endian == BIG_ENDIAN)
      q = ICV_BE.iconv(s)
    else
      q = ICV_LE.iconv(s)
    end
  rescue Iconv::InvalidCharacter
    q = 'Invalid character'
  rescue Iconv::IllegalSequence
    STDERR.printf("Iconv::IllegalSequence: [%s]\n", s)
    return ''
  end

  q << "\000\000"
  s_escape(q)
end

def conv_reg(endian, s)
  s = s.gsub(/\\([0-7]{2,3})\\([0-7]{2,3})/) {
              $1.to_i(8).chr + $2.to_i(8).chr
            }

  s = s.gsub(/\\x([0-9A-Fa-f]{2})\\x([0-9A-Fa-f]{2})/) {
              $1.to_i(16).chr + $2.to_i(16).chr
            }

  if (endian == BIG_ENDIAN)
    s = s.gsub(/(\\[0-7]{2,3})/) { "\\000" + $1 }
    s = s.gsub(/(\\x[0-9A-Fa-f]{2})/) { "\\x00" + $1 }
  else
    s = s.gsub(/(\\[0-7]{2,3})/) { $1 + "\\000" }
    s = s.gsub(/(\\x[0-9A-Fa-f]{2})/) { $1 + "\\x00" }
  end

  s = s.gsub(/\\/, '\\\\')  #'

  if (WINDOWS)
    s = s.gsub(/\?\?/, '?\\?')   # escape ANSI trigraph
  end
  conv_to_utf16(endian, s)
end

def conv_str(endian, s, from, to)
  if (s[0] == ?')
    s = s[1..-2]
    q = s.gsub(/\\/, '\\\\')  #'
  else
    q = s[1..-2]
    q.gsub!(/\\n/, "\x0a")
    q.gsub!(/\\t/, "\x09")
    q.gsub!(/\\v/, "\x0b")
    q.gsub!(/\\r/, "\x0d")
    q.gsub!(/\\f/, "\x0c")
    q.gsub!(/\\a/, "\x07")
    q.gsub!(/\\e/, "\x1b")

    q.gsub!(/\\([0-7]{2,3})/)      { $1.to_i(8).chr }
    q.gsub!(/\\x([0-9A-Fa-f]{2})/) { $1.to_i(16).chr }
  end

  from = from.to_i
  to   = to.to_i
  eucjp_from = eucjp_char_pos(q, from)
  eucjp_to   = eucjp_char_pos(q, to)

  s = conv_to_utf16(endian, q)

  from = utf16_byte_pos(endian, s, eucjp_from)
  to   = utf16_byte_pos(endian, s, eucjp_to)
  return s, from, to
end

print(<<"EOS")
/*
 * This program was generated by testconv.rb.
 */
#include<stdio.h>

#ifdef POSIX_TEST
#include "onigposix.h"
#else
#include "oniguruma.h"
#endif

static int nsucc  = 0;
static int nfail  = 0;
static int nerror = 0;

static FILE* err_file;

#ifndef POSIX_TEST
static OnigRegion* region;
static OnigEncoding ENC;
#endif

#define ulen(p) onigenc_str_bytelen_null(ENC, (UChar* )p)

static void uconv(char* from, char* to, int len)
{
  int i;
  unsigned char c;
  char *q;

  q = to;

  for (i = 0; i < len; i += 2) {
    c = (unsigned char )from[i];
    if (c == 0) {
      c = (unsigned char )from[i+1];
      if (c < 0x20 || c >= 0x7f || c == 0x5c || c == 0x22) {
        sprintf(q, "\\\\%03o", c);
        q += 4;
      }
      else {
        sprintf(q, "%c", c);
        q++;
      }
    }
    else {
      sprintf(q, "\\\\%03o", c);
      q += 4;
      c = (unsigned char )from[i+1];
      sprintf(q, "\\\\%03o", c);
      q += 4;
    }
  }

  *q = 0;
}

static void xx(char* pattern, char* str, int from, int to, int mem, int not)
{
  int r;
  char cpat[4000], cstr[4000];

#ifdef POSIX_TEST
  regex_t reg;
  char buf[200];
  regmatch_t pmatch[20];

  uconv(pattern, cpat, ulen(pattern));
  uconv(str,     cstr, ulen(str));

  r = regcomp(&reg, pattern, REG_EXTENDED | REG_NEWLINE);
  if (r) {
    regerror(r, &reg, buf, sizeof(buf));
    fprintf(err_file, "ERROR: %s\\n", buf);
    nerror++;
    return ;
  }

  r = regexec(&reg, str, reg.re_nsub + 1, pmatch, 0);
  if (r != 0 && r != REG_NOMATCH) {
    regerror(r, &reg, buf, sizeof(buf));
    fprintf(err_file, "ERROR: %s\\n", buf);
    nerror++;
    return ;
  }

  if (r == REG_NOMATCH) {
    if (not) {
      fprintf(stdout, "OK(N): /%s/ '%s'\\n", cpat, cstr);
      nsucc++;
    }
    else {
      fprintf(stdout, "FAIL: /%s/ '%s'\\n", cpat, cstr);
      nfail++;
    }
  }
  else {
    if (not) {
      fprintf(stdout, "FAIL(N): /%s/ '%s'\\n", cpat, cstr);
      nfail++;
    }
    else {
      if (pmatch[mem].rm_so == from && pmatch[mem].rm_eo == to) {
        fprintf(stdout, "OK: /%s/ '%s'\\n", cpat, cstr);
        nsucc++;
      }
      else {
        fprintf(stdout, "FAIL: /%s/ '%s' %d-%d : %d-%d\\n", cpat, cstr,
	        from, to, pmatch[mem].rm_so, pmatch[mem].rm_eo);
        nfail++;
      }
    }
  }
  regfree(&reg);

#else
  regex_t* reg;
  OnigCompileInfo ci;
  OnigErrorInfo einfo;
  OnigSyntaxType syn = *ONIG_SYNTAX_DEFAULT;

  /* ONIG_OPTION_OFF(syn.options, ONIG_OPTION_ASCII_RANGE); */

  uconv(pattern, cpat, ulen(pattern));
  uconv(str,     cstr, ulen(str));

#if 0
  r = onig_new(&reg, (UChar* )pattern, (UChar* )(pattern + ulen(pattern)),
	       ONIG_OPTION_DEFAULT, ENC, &syn, &einfo);
#else
  ci.num_of_elements = 5;
  ci.pattern_enc = ENC;
  ci.target_enc  = ENC;
  ci.syntax      = &syn;
  ci.option      = ONIG_OPTION_DEFAULT;
  ci.case_fold_flag = ONIGENC_CASE_FOLD_DEFAULT;

  r = onig_new_deluxe(&reg, (UChar* )pattern,
          (UChar* )(pattern + ulen(pattern)),
          &ci, &einfo);
#endif

  if (r) {
    char s[ONIG_MAX_ERROR_MESSAGE_LEN];
    onig_error_code_to_str(s, r, &einfo);
    fprintf(err_file, "ERROR: %s\\n", s);
    nerror++;
    return ;
  }

  r = onig_search(reg, (UChar* )str, (UChar* )(str + ulen(str)),
		  (UChar* )str, (UChar* )(str + ulen(str)),
		  region, ONIG_OPTION_NONE);
  if (r < ONIG_MISMATCH) {
    char s[ONIG_MAX_ERROR_MESSAGE_LEN];
    onig_error_code_to_str(s, r);
    fprintf(err_file, "ERROR: %s\\n", s);
    nerror++;
    return ;
  }

  if (r == ONIG_MISMATCH) {
    if (not) {
      fprintf(stdout, "OK(N): /%s/ '%s'\\n", cpat, cstr);
      nsucc++;
    }
    else {
      fprintf(stdout, "FAIL: /%s/ '%s'\\n", cpat, cstr);
      nfail++;
    }
  }
  else {
    if (not) {
      fprintf(stdout, "FAIL(N): /%s/ '%s'\\n", cpat, cstr);
      nfail++;
    }
    else {
      if (region->beg[mem] == from && region->end[mem] == to) {
        fprintf(stdout, "OK: /%s/ '%s'\\n", cpat, cstr);
        nsucc++;
      }
      else {
        fprintf(stdout, "FAIL: /%s/ '%s' %d-%d : %d-%d\\n", cpat, cstr,
	        from, to, region->beg[mem], region->end[mem]);
        nfail++;
      }
    }
  }
  onig_free(reg);
#endif
}

static void x2(char* pattern, char* str, int from, int to)
{
  xx(pattern, str, from, to, 0, 0);
}

static void x3(char* pattern, char* str, int from, int to, int mem)
{
  xx(pattern, str, from, to, mem, 0);
}

static void n(char* pattern, char* str)
{
  xx(pattern, str, 0, 0, 0, 1);
}

extern int main(int argc, char* argv[])
{
  err_file = stdout;

#ifndef POSIX_TEST
  region = onig_region_new();
#endif
EOS


PAT = '\\/([^\\\\\\/]*(?:\\\\.[^\\\\\\/]*)*)\\/'
CM  = /\s*,\s*/
RX2 = %r{\Ax\(#{PAT}#{CM}('[^']*'|"[^"]*")#{CM}(\S+)#{CM}(\S+)\)}
RI2 = %r{\Ai\(#{PAT}#{CM}('[^']*'|"[^"]*")#{CM}(\S+)#{CM}(\S+)\)}
RX3 = %r{\Ax\(#{PAT}#{CM}('[^']*'|"[^"]*")#{CM}(\S+)#{CM}(\S+)#{CM}(\S+)\)}
RN  = %r{\An\(#{PAT}#{CM}('[^']*'|"[^"]*")\)} #'

def convert(endian, fp)

  if (endian == BIG_ENDIAN)
    se = 'BE'
  else
    se = 'LE'
  end

  print(<<"EOS")
#ifdef POSIX_TEST
  reg_set_encoding(REG_POSIX_ENCODING_UTF16_#{se});
#else
  ENC = ONIG_ENCODING_UTF16_#{se};
#endif
EOS

  while line = fp.gets()
    if (m = RX2.match(line))
      reg = conv_reg(endian, m[1])
      str, from, to = conv_str(endian, m[2], m[3], m[4])
      printf("  x2(\"%s\", \"%s\", %s, %s);\n", reg, str, from, to)
    elsif (m = RI2.match(line))
      reg = conv_reg(endian, m[1])
      str, from, to = conv_str(endian, m[2], m[3], m[4])
      printf("  x2(\"%s\", \"%s\", %s, %s);\n", reg, str, from, to)
    elsif (m = RX3.match(line))
      reg = conv_reg(endian, m[1])
      str, from, to = conv_str(endian, m[2], m[3], m[4])
      printf("  x3(\"%s\", \"%s\", %s, %s, %s);\n", reg, str, from, to, m[5])
    elsif (m = RN.match(line))
      reg = conv_reg(endian, m[1])
      str, from, to = conv_str(endian, m[2], 0, 0)
      printf("  n(\"%s\", \"%s\");\n", reg, str)
    else
    end
  end
end

File::open(ARGV[0]) { |fp|
  convert(BIG_ENDIAN, fp)
}

#File::open(ARGV[0]) { |fp|
#  convert(LITTLE_ENDIAN, fp)
#}

ICV_BE.close
ICV_LE.close

print(<<'EOS')
  fprintf(stdout,
       "\nRESULT   SUCC: %d,  FAIL: %d,  ERROR: %d      (by Onigmo %s)\n",
       nsucc, nfail, nerror, onig_version());

#ifndef POSIX_TEST
  onig_region_free(region, 1);
  onig_end();
#endif

  return ((nfail == 0 && nerror == 0) ? 0 : -1);
}
EOS

# END OF SCRIPT
