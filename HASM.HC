// ============================================================
//  Assembler x86-64 em HolyC  —  para TempleOS
//  Suporta: MOV, ADD, SUB, AND, OR, XOR, CMP, TEST,
//           INC, DEC, NOT, NEG, SHL, SHR, SAR,
//           PUSH, POP, CALL, RET, JMP, Jcc,
//           IMUL, NOP, HLT, SYSCALL, INT
//           Diretivas: DB, DW, DD, DQ, SECTION, GLOBAL
// ============================================================

#define MAX_TOKENS   16
#define MAX_LABELS   512
#define MAX_FIXUPS   512
#define MAX_OUTPUT   65536
#define TOK_LEN      64
#define LINE_LEN     512

// ── Tipos de token ───────────────────────────────────────────
#define TOK_NONE     0
#define TOK_IDENT    1
#define TOK_NUMBER   2
#define TOK_COMMA    3
#define TOK_LBRACK   4
#define TOK_RBRACK   5
#define TOK_PLUS     6
#define TOK_MINUS    7
#define TOK_COLON    8
#define TOK_STRING   9

// ── Tamanhos de operando ──────────────────────────────────────
#define SZ_8    1
#define SZ_16   2
#define SZ_32   4
#define SZ_64   8

// ── Encodings de registrador (número físico 0-15) ─────────────
#define REG_RAX  0
#define REG_RCX  1
#define REG_RDX  2
#define REG_RBX  3
#define REG_RSP  4
#define REG_RBP  5
#define REG_RSI  6
#define REG_RDI  7

// ── Estruturas ────────────────────────────────────────────────
class Token {
  I64  type;
  U8   str[TOK_LEN];
  I64  num;
};

class AsmLabel {
  U8  name[TOK_LEN];
  I64 addr;
};

class AsmFixup {
  U8  label[TOK_LEN];
  I64 offset;    // posição no buffer onde patchear
  I64 size;      // 1 = rel8, 4 = rel32/abs32
  I64 rel_base;  // base para cálculo relativo (0 = absoluto)
};

// ── Estado global do assembler ────────────────────────────────
U8       g_out[MAX_OUTPUT];
I64      g_pos        = 0;
AsmLabel g_labels[MAX_LABELS];
I64      g_lbl_count  = 0;
AsmFixup g_fixups[MAX_FIXUPS];
I64      g_fix_count  = 0;
I64      g_errors     = 0;
I64      g_line_num   = 0;

// ═════════════════════════════════════════════════════════════
//  Emissão de bytes
// ═════════════════════════════════════════════════════════════

U0 Emit8(U8 b) {
  if (g_pos >= MAX_OUTPUT) { Print("ERRO: buffer de saída cheio\n"); g_errors++; return; }
  g_out[g_pos++] = b;
}

U0 Emit16(U16 v) {
  Emit8(v & 0xFF);
  Emit8((v >> 8) & 0xFF);
}

U0 Emit32(U32 v) {
  Emit8(v & 0xFF);
  Emit8((v >>  8) & 0xFF);
  Emit8((v >> 16) & 0xFF);
  Emit8((v >> 24) & 0xFF);
}

U0 Emit64(U64 v) {
  Emit32(v & 0xFFFFFFFF);
  Emit32((v >> 32) & 0xFFFFFFFF);
}

// ═════════════════════════════════════════════════════════════
//  Labels e fixups
// ═════════════════════════════════════════════════════════════

U0 LabelAdd(U8 *name, I64 addr) {
  if (g_lbl_count >= MAX_LABELS) { Print("ERRO: muitos labels\n"); return; }
  StrCpy(g_labels[g_lbl_count].name, name);
  g_labels[g_lbl_count].addr = addr;
  g_lbl_count++;
}

I64 LabelFind(U8 *name) {
  I64 i;
  for (i = 0; i < g_lbl_count; i++)
    if (!StrCmp(g_labels[i].name, name)) return g_labels[i].addr;
  return -1;
}

U0 FixupAdd(U8 *label, I64 offset, I64 size, I64 rel_base) {
  if (g_fix_count >= MAX_FIXUPS) { Print("ERRO: muitos fixups\n"); return; }
  StrCpy(g_fixups[g_fix_count].label, label);
  g_fixups[g_fix_count].offset   = offset;
  g_fixups[g_fix_count].size     = size;
  g_fixups[g_fix_count].rel_base = rel_base;
  g_fix_count++;
}

U0 FixupsApply() {
  I64 i, addr, val;
  for (i = 0; i < g_fix_count; i++) {
    addr = LabelFind(g_fixups[i].label);
    if (addr < 0) {
      Print("ERRO: label indefinido '%s'\n", g_fixups[i].label);
      g_errors++; continue;
    }
    val = (g_fixups[i].rel_base > 0) ? addr - g_fixups[i].rel_base : addr;
    if (g_fixups[i].size == 1) {
      g_out[g_fixups[i].offset] = val & 0xFF;
    } else {
      g_out[g_fixups[i].offset    ] =  val        & 0xFF;
      g_out[g_fixups[i].offset + 1] = (val >>  8) & 0xFF;
      g_out[g_fixups[i].offset + 2] = (val >> 16) & 0xFF;
      g_out[g_fixups[i].offset + 3] = (val >> 24) & 0xFF;
    }
  }
}

// ═════════════════════════════════════════════════════════════
//  Tokenizador
// ═════════════════════════════════════════════════════════════

U0 ToUpper(U8 *s) {
  while (*s) { if (*s >= 'a' && *s <= 'z') *s -= 32; s++; }
}

I64 IsAlpha(U8 c) {
  return (c>='a'&&c<='z') || (c>='A'&&c<='Z') || c=='_' || c=='.';
}
I64 IsAlNum(U8 c) { return IsAlpha(c) || (c>='0'&&c<='9'); }
I64 IsDigit(U8 c) { return c>='0'&&c<='9'; }

I64 ParseNum(U8 *s, U8 **end_out) {
  I64 neg=0, val=0;
  if (*s=='-') { neg=1; s++; }
  if (s[0]=='0' && (s[1]=='x'||s[1]=='X')) {
    s += 2;
    while ((*s>='0'&&*s<='9')||(*s>='a'&&*s<='f')||(*s>='A'&&*s<='F')) {
      val <<= 4;
      if (*s<='9') val += *s-'0';
      else if (*s<='F') val += *s-'A'+10;
      else val += *s-'a'+10;
      s++;
    }
  } else {
    while (*s>='0'&&*s<='9') { val=val*10+(*s-'0'); s++; }
  }
  if (end_out) *end_out = s;
  return neg ? -val : val;
}

I64 Tokenize(U8 *line, Token *toks) {
  I64 n=0, k;
  U8 *p = line, *e;

  while (*p==' '||*p=='\t') p++;

  while (*p && *p!='\n' && *p!='\r' && *p!=';' && n<MAX_TOKENS) {
    while (*p==' '||*p=='\t') p++;
    if (!*p||*p=='\n'||*p=='\r'||*p==';') break;

    if (*p==',')       { toks[n].type=TOK_COMMA;  toks[n].str[0]=','; toks[n].str[1]=0; n++; p++; }
    else if (*p=='[')  { toks[n].type=TOK_LBRACK; toks[n].str[0]='['; toks[n].str[1]=0; n++; p++; }
    else if (*p==']')  { toks[n].type=TOK_RBRACK; toks[n].str[0]=']'; toks[n].str[1]=0; n++; p++; }
    else if (*p=='+')  { toks[n].type=TOK_PLUS;   toks[n].str[0]='+'; toks[n].str[1]=0; n++; p++; }
    else if (*p==':')  { toks[n].type=TOK_COLON;  toks[n].str[0]=':'; toks[n].str[1]=0; n++; p++; }
    else if (*p=='-' && !IsDigit(*(p+1))) {
      toks[n].type=TOK_MINUS; toks[n].str[0]='-'; toks[n].str[1]=0; n++; p++;
    }
    else if (IsDigit(*p) || (*p=='-'&&IsDigit(*(p+1))) || (*p=='0'&&(*(p+1)=='x'||*(p+1)=='X'))) {
      toks[n].type = TOK_NUMBER;
      toks[n].num  = ParseNum(p, &e);
      k=0; while (p<e&&k<TOK_LEN-1) toks[n].str[k++]=*p++;
      toks[n].str[k]=0; n++;
    }
    else if (IsAlpha(*p)) {
      k=0; while (IsAlNum(*p)&&k<TOK_LEN-1) toks[n].str[k++]=*p++;
      toks[n].str[k]=0; toks[n].type=TOK_IDENT; n++;
    }
    else p++;
  }
  return n;
}

// ═════════════════════════════════════════════════════════════
//  Lookup de registradores
// ═════════════════════════════════════════════════════════════

I64 GetReg(U8 *name, I64 *sz) {
  U8 up[TOK_LEN];
  StrCpy(up, name); ToUpper(up);

  // 64-bit
  if (!StrCmp(up,"RAX")){*sz=SZ_64;return 0;} if (!StrCmp(up,"RCX")){*sz=SZ_64;return 1;}
  if (!StrCmp(up,"RDX")){*sz=SZ_64;return 2;} if (!StrCmp(up,"RBX")){*sz=SZ_64;return 3;}
  if (!StrCmp(up,"RSP")){*sz=SZ_64;return 4;} if (!StrCmp(up,"RBP")){*sz=SZ_64;return 5;}
  if (!StrCmp(up,"RSI")){*sz=SZ_64;return 6;} if (!StrCmp(up,"RDI")){*sz=SZ_64;return 7;}
  if (!StrCmp(up,"R8" )){*sz=SZ_64;return 8;} if (!StrCmp(up,"R9" )){*sz=SZ_64;return 9;}
  if (!StrCmp(up,"R10")){*sz=SZ_64;return 10;}if (!StrCmp(up,"R11")){*sz=SZ_64;return 11;}
  if (!StrCmp(up,"R12")){*sz=SZ_64;return 12;}if (!StrCmp(up,"R13")){*sz=SZ_64;return 13;}
  if (!StrCmp(up,"R14")){*sz=SZ_64;return 14;}if (!StrCmp(up,"R15")){*sz=SZ_64;return 15;}

  // 32-bit
  if (!StrCmp(up,"EAX")){*sz=SZ_32;return 0;} if (!StrCmp(up,"ECX")){*sz=SZ_32;return 1;}
  if (!StrCmp(up,"EDX")){*sz=SZ_32;return 2;} if (!StrCmp(up,"EBX")){*sz=SZ_32;return 3;}
  if (!StrCmp(up,"ESP")){*sz=SZ_32;return 4;} if (!StrCmp(up,"EBP")){*sz=SZ_32;return 5;}
  if (!StrCmp(up,"ESI")){*sz=SZ_32;return 6;} if (!StrCmp(up,"EDI")){*sz=SZ_32;return 7;}
  if (!StrCmp(up,"R8D")){*sz=SZ_32;return 8;} if (!StrCmp(up,"R9D")){*sz=SZ_32;return 9;}

  // 16-bit
  if (!StrCmp(up,"AX")){*sz=SZ_16;return 0;} if (!StrCmp(up,"CX")){*sz=SZ_16;return 1;}
  if (!StrCmp(up,"DX")){*sz=SZ_16;return 2;} if (!StrCmp(up,"BX")){*sz=SZ_16;return 3;}
  if (!StrCmp(up,"SP")){*sz=SZ_16;return 4;} if (!StrCmp(up,"BP")){*sz=SZ_16;return 5;}
  if (!StrCmp(up,"SI")){*sz=SZ_16;return 6;} if (!StrCmp(up,"DI")){*sz=SZ_16;return 7;}

  // 8-bit
  if (!StrCmp(up,"AL")){*sz=SZ_8;return 0;} if (!StrCmp(up,"CL")){*sz=SZ_8;return 1;}
  if (!StrCmp(up,"DL")){*sz=SZ_8;return 2;} if (!StrCmp(up,"BL")){*sz=SZ_8;return 3;}
  if (!StrCmp(up,"AH")){*sz=SZ_8;return 4;} if (!StrCmp(up,"CH")){*sz=SZ_8;return 5;}
  if (!StrCmp(up,"DH")){*sz=SZ_8;return 6;} if (!StrCmp(up,"BH")){*sz=SZ_8;return 7;}

  return -1;
}

// ═════════════════════════════════════════════════════════════
//  Helpers de encoding
// ═════════════════════════════════════════════════════════════

U8 ModRM(U8 mod, U8 reg, U8 rm) {
  return (mod<<6) | ((reg&7)<<3) | (rm&7);
}

// Emite REX se necessário
U0 EmitREX(I64 W, I64 R, I64 X, I64 B) {
  U8 rex = 0x40 | (W?8:0) | (R?4:0) | (X?2:0) | (B?1:0);
  Emit8(rex);
}

// Prefixo + REX para operação de dois registradores
U0 PrepareReg2(I64 sz, I64 dst, I64 src) {
  if (sz==SZ_16) Emit8(0x66);
  if (sz==SZ_64 || dst>=8 || src>=8)
    EmitREX(sz==SZ_64, src>=8, 0, dst>=8);
}

// Prepara para operação reg + imm
U0 PrepareRegImm(I64 sz, I64 dst) {
  if (sz==SZ_16) Emit8(0x66);
  if (sz==SZ_64 || dst>=8)
    EmitREX(sz==SZ_64, 0, 0, dst>=8);
}

// ═════════════════════════════════════════════════════════════
//  Encoder de instruções
// ═════════════════════════════════════════════════════════════

U0 EncodeInstr(Token *t, I64 n) {
  if (n==0) return;

  U8 mn[TOK_LEN];
  StrCpy(mn, t[0].str); ToUpper(mn);

  I64 r1, r2, sz1, sz2, imm, addr;

  // ── NOP ──────────────────────────────────────────────────
  if (!StrCmp(mn,"NOP"))     { Emit8(0x90); return; }

  // ── RET ──────────────────────────────────────────────────
  if (!StrCmp(mn,"RET"))     { Emit8(0xC3); return; }

  // ── HLT ──────────────────────────────────────────────────
  if (!StrCmp(mn,"HLT"))     { Emit8(0xF4); return; }

  // ── SYSCALL ───────────────────────────────────────────────
  if (!StrCmp(mn,"SYSCALL")) { Emit8(0x0F); Emit8(0x05); return; }

  // ── INT imm8 ──────────────────────────────────────────────
  if (!StrCmp(mn,"INT") && n>=2 && t[1].type==TOK_NUMBER) {
    if (t[1].num==3) { Emit8(0xCC); }
    else             { Emit8(0xCD); Emit8(t[1].num&0xFF); }
    return;
  }

  // ── PUSH ──────────────────────────────────────────────────
  if (!StrCmp(mn,"PUSH") && n>=2) {
    r1 = GetReg(t[1].str, &sz1);
    if (r1>=0 && sz1==SZ_64) {
      if (r1>=8) EmitREX(0,0,0,1);
      Emit8(0x50+(r1&7)); return;
    }
    if (t[1].type==TOK_NUMBER) {
      imm=t[1].num;
      if (imm>=-128&&imm<=127) { Emit8(0x6A); Emit8(imm&0xFF); }
      else                     { Emit8(0x68); Emit32(imm); }
      return;
    }
  }

  // ── POP ───────────────────────────────────────────────────
  if (!StrCmp(mn,"POP") && n>=2) {
    r1 = GetReg(t[1].str, &sz1);
    if (r1>=0 && sz1==SZ_64) {
      if (r1>=8) EmitREX(0,0,0,1);
      Emit8(0x58+(r1&7)); return;
    }
  }

  // ── INC / DEC ─────────────────────────────────────────────
  if ((!StrCmp(mn,"INC")||!StrCmp(mn,"DEC")) && n>=2) {
    I64 is_dec = !StrCmp(mn,"DEC");
    r1 = GetReg(t[1].str, &sz1);
    if (r1>=0) {
      PrepareRegImm(sz1, r1);
      Emit8(sz1==SZ_8 ? 0xFE : 0xFF);
      Emit8(ModRM(3, is_dec?1:0, r1&7));
      return;
    }
  }

  // ── NOT / NEG ─────────────────────────────────────────────
  if ((!StrCmp(mn,"NOT")||!StrCmp(mn,"NEG")) && n>=2) {
    I64 digit = !StrCmp(mn,"NEG") ? 3 : 2;
    r1 = GetReg(t[1].str, &sz1);
    if (r1>=0) {
      PrepareRegImm(sz1, r1);
      Emit8(sz1==SZ_8 ? 0xF6 : 0xF7);
      Emit8(ModRM(3, digit, r1&7));
      return;
    }
  }

  // ── JMP ───────────────────────────────────────────────────
  if (!StrCmp(mn,"JMP") && n>=2) {
    if (t[1].type==TOK_IDENT) {
      r1=GetReg(t[1].str,&sz1);
      if (r1>=0 && sz1==SZ_64) {           // JMP r64
        if (r1>=8) EmitREX(0,0,0,1);
        Emit8(0xFF); Emit8(ModRM(3,4,r1&7));
      } else {                              // JMP label (rel32)
        Emit8(0xE9);
        addr=LabelFind(t[1].str);
        if (addr<0) { FixupAdd(t[1].str,g_pos,4,g_pos+4); Emit32(0); }
        else        { Emit32(addr-(g_pos+4)); }
      }
      return;
    }
    if (t[1].type==TOK_NUMBER) {
      imm=t[1].num;
      if (imm>=-128&&imm<=127) { Emit8(0xEB); Emit8(imm&0xFF); }
      else                     { Emit8(0xE9); Emit32(imm); }
      return;
    }
  }

  // ── CALL ──────────────────────────────────────────────────
  if (!StrCmp(mn,"CALL") && n>=2) {
    if (t[1].type==TOK_IDENT) {
      r1=GetReg(t[1].str,&sz1);
      if (r1>=0 && sz1==SZ_64) {           // CALL r64
        if (r1>=8) EmitREX(0,0,0,1);
        Emit8(0xFF); Emit8(ModRM(3,2,r1&7));
      } else {                              // CALL label (rel32)
        Emit8(0xE8);
        addr=LabelFind(t[1].str);
        if (addr<0) { FixupAdd(t[1].str,g_pos,4,g_pos+4); Emit32(0); }
        else        { Emit32(addr-(g_pos+4)); }
      }
      return;
    }
    if (t[1].type==TOK_NUMBER) { Emit8(0xE8); Emit32(t[1].num); return; }
  }

  // ── Jcc (saltos condicionais) ─────────────────────────────
  {
    U8  jcc_mn[][8] = {"JE","JZ","JNE","JNZ","JL","JNGE","JLE","JNG",
                        "JG","JNLE","JGE","JNL","JB","JC","JBE","JNAE",
                        "JA","JNBE","JAE","JNC","JS","JNS","JP","JPE",
                        "JNP","JPO","JO","JNO","JRCXZ"};
    U8  jcc_op[] =    {0x74,0x74,0x75,0x75,0x7C,0x7C,0x7E,0x7E,
                        0x7F,0x7F,0x7D,0x7D,0x72,0x72,0x76,0x76,
                        0x77,0x77,0x73,0x73,0x78,0x79,0x7A,0x7A,
                        0x7B,0x7B,0x70,0x71,0xE3};
    I64 njcc=29, i;
    for (i=0; i<njcc; i++) {
      if (!StrCmp(mn, jcc_mn[i]) && n>=2) {
        I64 disp8=0;
        if (t[1].type==TOK_IDENT) {
          addr=LabelFind(t[1].str);
          if (addr<0) {
            Emit8(jcc_op[i]);
            FixupAdd(t[1].str, g_pos, 1, g_pos+1);
            Emit8(0);
          } else {
            disp8=addr-(g_pos+2);
            Emit8(jcc_op[i]); Emit8(disp8&0xFF);
          }
        } else if (t[1].type==TOK_NUMBER) {
          Emit8(jcc_op[i]); Emit8(t[1].num&0xFF);
        }
        return;
      }
    }
  }

  // ── Instruções de dois operandos: dst, src ─────────────────
  // Formato: MNEM dst , src   →  t[0] t[1] t[2]=COMMA t[3]
  if (n>=4 && t[2].type==TOK_COMMA) {
    r1=GetReg(t[1].str,&sz1);   // dst
    r2=GetReg(t[3].str,&sz2);   // src (pode ser -1 se imm/label)

    // ── MOV ────────────────────────────────────────────────
    if (!StrCmp(mn,"MOV")) {
      if (r1>=0 && r2>=0) {                 // MOV r, r
        PrepareReg2(sz1, r1, r2);
        Emit8(sz1==SZ_8 ? 0x88 : 0x89);
        Emit8(ModRM(3, r2&7, r1&7)); return;
      }
      if (r1>=0 && t[3].type==TOK_NUMBER) { // MOV r, imm
        imm=t[3].num;
        if (sz1==SZ_64) {
          if (imm>=-2147483648 && imm<=2147483647) {
            EmitREX(1,0,0,r1>=8); Emit8(0xC7); Emit8(ModRM(3,0,r1&7)); Emit32(imm);
          } else {
            EmitREX(1,0,0,r1>=8); Emit8(0xB8+(r1&7)); Emit64(imm);
          }
        } else if (sz1==SZ_32) {
          if (r1>=8) EmitREX(0,0,0,1);
          Emit8(0xB8+(r1&7)); Emit32(imm);
        } else if (sz1==SZ_16) {
          Emit8(0x66); Emit8(0xB8+(r1&7)); Emit16(imm);
        } else {
          Emit8(0xB0+(r1&7)); Emit8(imm&0xFF);
        }
        return;
      }
      if (r1>=0 && t[3].type==TOK_IDENT) { // MOV r64, label
        addr=LabelFind(t[3].str);
        if (sz1==SZ_64) {
          EmitREX(1,0,0,r1>=8); Emit8(0xB8+(r1&7));
          if (addr<0) { FixupAdd(t[3].str,g_pos,4,0); Emit64(0); }
          else        { Emit64(addr); }
        }
        return;
      }
    }

    // ── ALU: ADD OR ADC SBB AND SUB XOR CMP ───────────────
    {
      U8  alu_mn[][4]={"ADD","OR","ADC","SBB","AND","SUB","XOR","CMP"};
      U8  alu_r8[] =  {0x00,0x08,0x10,0x18,0x20,0x28,0x30,0x38};
      U8  alu_r[]  =  {0x01,0x09,0x11,0x19,0x21,0x29,0x31,0x39};
      U8  alu_d[]  =  {0,   1,   2,   3,   4,   5,   6,   7  };
      I64 i;
      for (i=0; i<8; i++) {
        if (!StrCmp(mn,alu_mn[i])) {
          if (r1>=0 && r2>=0) {            // reg, reg
            PrepareReg2(sz1,r1,r2);
            Emit8(sz1==SZ_8 ? alu_r8[i] : alu_r[i]);
            Emit8(ModRM(3,r2&7,r1&7)); return;
          }
          if (r1>=0 && t[3].type==TOK_NUMBER) { // reg, imm
            imm=t[3].num;
            PrepareRegImm(sz1,r1);
            if (sz1==SZ_8) {
              Emit8(0x80); Emit8(ModRM(3,alu_d[i],r1&7)); Emit8(imm&0xFF);
            } else if (imm>=-128&&imm<=127) {
              Emit8(0x83); Emit8(ModRM(3,alu_d[i],r1&7)); Emit8(imm&0xFF);
            } else {
              Emit8(0x81); Emit8(ModRM(3,alu_d[i],r1&7));
              if (sz1==SZ_16) Emit16(imm); else Emit32(imm);
            }
            return;
          }
          break;
        }
      }
    }

    // ── TEST ───────────────────────────────────────────────
    if (!StrCmp(mn,"TEST")) {
      if (r1>=0 && r2>=0) {
        PrepareReg2(sz1,r1,r2);
        Emit8(sz1==SZ_8 ? 0x84 : 0x85); Emit8(ModRM(3,r2&7,r1&7)); return;
      }
      if (r1>=0 && t[3].type==TOK_NUMBER) {
        imm=t[3].num; PrepareRegImm(sz1,r1);
        if (sz1==SZ_8) { Emit8(0xF6); Emit8(ModRM(3,0,r1&7)); Emit8(imm&0xFF); }
        else           { Emit8(0xF7); Emit8(ModRM(3,0,r1&7)); Emit32(imm); }
        return;
      }
    }

    // ── IMUL r64, r64 ─────────────────────────────────────
    if (!StrCmp(mn,"IMUL") && r1>=0 && r2>=0) {
      PrepareReg2(sz1,r1,r2);
      Emit8(0x0F); Emit8(0xAF); Emit8(ModRM(3,r1&7,r2&7)); return;
    }

    // ── XCHG ──────────────────────────────────────────────
    if (!StrCmp(mn,"XCHG") && r1>=0 && r2>=0) {
      PrepareReg2(sz1,r1,r2);
      Emit8(sz1==SZ_8 ? 0x86 : 0x87); Emit8(ModRM(3,r1&7,r2&7)); return;
    }

    // ── Shifts: SHL SHR SAR ROL ROR ──────────────────────
    {
      U8  sh_mn[][4]={"SHL","SHR","SAR","ROL","ROR"};
      U8  sh_d[] =   {4,    5,    7,    0,    1   };
      I64 i;
      U8  up3[TOK_LEN]; StrCpy(up3,t[3].str); ToUpper(up3);
      for (i=0; i<5; i++) {
        if (!StrCmp(mn,sh_mn[i]) && r1>=0) {
          PrepareRegImm(sz1,r1);
          if (!StrCmp(up3,"CL")) {
            Emit8(sz1==SZ_8 ? 0xD2 : 0xD3); Emit8(ModRM(3,sh_d[i],r1&7));
          } else if (t[3].type==TOK_NUMBER && t[3].num==1) {
            Emit8(sz1==SZ_8 ? 0xD0 : 0xD1); Emit8(ModRM(3,sh_d[i],r1&7));
          } else if (t[3].type==TOK_NUMBER) {
            Emit8(sz1==SZ_8 ? 0xC0 : 0xC1); Emit8(ModRM(3,sh_d[i],r1&7));
            Emit8(t[3].num & 0x3F);
          }
          return;
        }
      }
    }

    // ── LEA r64, [base +/- disp] ──────────────────────────
    if (!StrCmp(mn,"LEA") && r1>=0 && t[3].type==TOK_LBRACK && n>=6) {
      r2=GetReg(t[4].str,&sz2);
      if (r2>=0) {
        I64 disp=0; I64 has_d=0;
        if (n>=8 && (t[5].type==TOK_PLUS||t[5].type==TOK_MINUS) && t[6].type==TOK_NUMBER) {
          disp = t[5].type==TOK_MINUS ? -t[6].num : t[6].num;
          has_d=1;
        }
        PrepareReg2(sz1,r2,r1);
        Emit8(0x8D);
        if (!has_d && r2!=REG_RBP) {
          Emit8(ModRM(0,r1&7,r2&7));
          if ((r2&7)==4) Emit8(0x24);
        } else if (disp>=-128&&disp<=127) {
          Emit8(ModRM(1,r1&7,r2&7)); if ((r2&7)==4) Emit8(0x24); Emit8(disp&0xFF);
        } else {
          Emit8(ModRM(2,r1&7,r2&7)); if ((r2&7)==4) Emit8(0x24); Emit32(disp);
        }
        return;
      }
    }
  }

  // ── Diretivas de dados ────────────────────────────────────
  if (!StrCmp(mn,"DB")) {
    I64 i;
    for (i=1;i<n;i++) { if (t[i].type==TOK_NUMBER) Emit8(t[i].num&0xFF); }
    return;
  }
  if (!StrCmp(mn,"DW")) {
    I64 i;
    for (i=1;i<n;i++) { if (t[i].type==TOK_NUMBER) Emit16(t[i].num); }
    return;
  }
  if (!StrCmp(mn,"DD")) {
    I64 i;
    for (i=1;i<n;i++) { if (t[i].type==TOK_NUMBER) Emit32(t[i].num); }
    return;
  }
  if (!StrCmp(mn,"DQ")) {
    I64 i;
    for (i=1;i<n;i++) { if (t[i].type==TOK_NUMBER) Emit64(t[i].num); }
    return;
  }

  // ── Diretivas ignoradas silenciosamente ───────────────────
  if (!StrCmp(mn,"SECTION")||!StrCmp(mn,"GLOBAL")||
      !StrCmp(mn,"EXTERN") ||!StrCmp(mn,"BITS")  ||
      !StrCmp(mn,"ORG")    ||!StrCmp(mn,"ALIGN")) return;

  Print("Linha %d: instrucao desconhecida '%s'\n", g_line_num, mn);
  g_errors++;
}

// ═════════════════════════════════════════════════════════════
//  Processar uma linha
// ═════════════════════════════════════════════════════════════

U0 AssembleLine(U8 *line) {
  Token toks[MAX_TOKENS];
  I64   n = Tokenize(line, toks);
  I64   i;

  if (n==0) return;

  // Detecta label: IDENT seguido de ':'
  if (n>=2 && toks[0].type==TOK_IDENT && toks[1].type==TOK_COLON) {
    LabelAdd(toks[0].str, g_pos);
    // Desloca tokens (remove label e ':')
    for (i=0; i<n-2; i++) MemCpy(&toks[i], &toks[i+2], sizeof(Token));
    n -= 2;
  }

  if (n>0) EncodeInstr(toks, n);
}

// ═════════════════════════════════════════════════════════════
//  Montar um bloco de texto
// ═════════════════════════════════════════════════════════════

U0 Assemble(U8 *src) {
  // Reset estado
  g_pos=0; g_lbl_count=0; g_fix_count=0; g_errors=0; g_line_num=0;
  MemSet(g_out, 0, MAX_OUTPUT);

  U8  line[LINE_LEN];
  U8  *p = src;
  I64 k;

  while (*p) {
    k=0;
    while (*p && *p!='\n') { if (k<LINE_LEN-1) line[k++]=*p; p++; }
    line[k]=0;
    if (*p=='\n') p++;
    g_line_num++;
    AssembleLine(line);
  }

  FixupsApply();

  if (g_errors>0)
    Print("\nAssembly concluido com %d erro(s).\n", g_errors);
  else
    Print("\nAssembly OK — %d bytes gerados.\n", g_pos);
}

// ═════════════════════════════════════════════════════════════
//  Saída: hex dump e salvar arquivo
// ═════════════════════════════════════════════════════════════

U0 HexDump() {
  I64 i;
  Print("\n── Hex Dump (%d bytes) ──────────────────────\n", g_pos);
  for (i=0; i<g_pos; i++) {
    if (i%16==0) Print("%04X: ", i);
    Print("%02X ", g_out[i]);
    if (i%16==15 || i==g_pos-1) Print("\n");
  }
  Print("─────────────────────────────────────────────\n");
}

U0 HexDumpLabels() {
  I64 i;
  if (g_lbl_count==0) { Print("(nenhum label)\n"); return; }
  Print("\n── Labels ───────────────────────────────────\n");
  for (i=0; i<g_lbl_count; i++)
    Print("  %-20s  0x%04X (%d)\n", g_labels[i].name, g_labels[i].addr, g_labels[i].addr);
  Print("─────────────────────────────────────────────\n");
}

U0 SaveBin(U8 *filename) {
  FileWrite(filename, g_out, g_pos);
  Print("Arquivo salvo: '%s' (%d bytes)\n", filename, g_pos);
}

// ═════════════════════════════════════════════════════════════
//  Montar a partir de arquivo
// ═════════════════════════════════════════════════════════════

U0 AssembleFile(U8 *infile, U8 *outfile=NULL) {
  U8 *src = FileRead(infile);
  if (!src) { Print("ERRO: nao foi possivel ler '%s'\n", infile); return; }
  Assemble(src);
  Free(src);
  HexDump();
  HexDumpLabels();
  if (outfile) SaveBin(outfile);
}

// ═════════════════════════════════════════════════════════════
//  Testes embutidos
// ═════════════════════════════════════════════════════════════

U0 TestBasico() {
  Print("\n╔══════════════════════════════════════╗\n");
  Print("║   Teste 1 — Linux Hello World x64   ║\n");
  Print("╚══════════════════════════════════════╝\n");

  U8 *src =
    "section .text\n"
    "global _start\n"
    "\n"
    "_start:\n"
    "  mov rax, 1       ; sys_write\n"
    "  mov rdi, 1       ; stdout\n"
    "  mov rsi, 0x1000  ; buffer\n"
    "  mov rdx, 13      ; len\n"
    "  syscall\n"
    "\n"
    "  mov rax, 60      ; sys_exit\n"
    "  xor rdi, rdi\n"
    "  syscall\n";

  Assemble(src);
  HexDump();
  HexDumpLabels();
}

U0 TestALU() {
  Print("\n╔══════════════════════════════════════╗\n");
  Print("║   Teste 2 — Operacoes ALU variadas  ║\n");
  Print("╚══════════════════════════════════════╝\n");

  U8 *src =
    "  nop\n"
    "  mov rax, 42\n"
    "  mov rbx, rax\n"
    "  add rax, 8\n"
    "  sub rbx, 3\n"
    "  and rax, 0xFF\n"
    "  or  rbx, 0x10\n"
    "  xor rcx, rcx\n"
    "  shl rax, 2\n"
    "  shr rbx, 1\n"
    "  sar rcx, cl\n"
    "  inc rdi\n"
    "  dec rsi\n"
    "  neg rax\n"
    "  not rbx\n"
    "  imul rax, rbx\n"
    "  push rax\n"
    "  pop  rbx\n"
    "  ret\n";

  Assemble(src);
  HexDump();
}

U0 TestSaltos() {
  Print("\n╔══════════════════════════════════════╗\n");
  Print("║   Teste 3 — Saltos e labels         ║\n");
  Print("╚══════════════════════════════════════╝\n");

  U8 *src =
    "inicio:\n"
    "  xor rcx, rcx\n"
    "loop:\n"
    "  inc rcx\n"
    "  cmp rcx, 10\n"
    "  jl  loop\n"
    "  jmp fim\n"
    "meio:\n"
    "  nop\n"
    "fim:\n"
    "  ret\n";

  Assemble(src);
  HexDump();
  HexDumpLabels();
}

U0 TestDB() {
  Print("\n╔══════════════════════════════════════╗\n");
  Print("║   Teste 4 — Diretivas DB/DW/DD/DQ  ║\n");
  Print("╚══════════════════════════════════════╝\n");

  U8 *src =
    "DB 0x90, 0x90, 0x90\n"
    "DW 0x1234\n"
    "DD 0xDEADBEEF\n"
    "DQ 0x0102030405060708\n";

  Assemble(src);
  HexDump();
}

U0 RunAllTests() {
  TestBasico;
  TestALU;
  TestSaltos;
  TestDB;
  Print("\nTodos os testes concluidos.\n");
}

// ═════════════════════════════════════════════════════════════
//  Ponto de entrada principal
// ═════════════════════════════════════════════════════════════

Print("Assembler x86-64 em HolyC carregado.\n");
Print("Funcoes disponiveis:\n");
Print("  Assemble(src_str)        — monta string\n");
Print("  AssembleFile(in, out)    — monta arquivo\n");
Print("  HexDump()                — mostra saida atual\n");
Print("  HexDumpLabels()          — mostra tabela de labels\n");
Print("  SaveBin(filename)        — salva binario\n");
Print("  RunAllTests()            — roda todos os testes\n\n");
