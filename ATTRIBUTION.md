# ATTRIBUTIONS

This project values open-source contributions and strives to properly credit the work of others. We recognize third-party works, designs, ideas, and code that have influenced or been incorporated into this project, regardless of licensing requirements.

If you believe we have missed or misattributed any content, please open an issue or contact Matt Dunleavy <mdunleavy@excedra.com> so that we can make the appropriate acknowledgment.

---

## The Lua Programming Language

Prolua is an independent implementation of the [Lua](https://www.lua.org/) programming language. It would not exist without the language, design, and decades of work created and maintained by the Lua team.

Lua has been designed, implemented, and maintained at the Pontifical Catholic University of Rio de Janeiro ([PUC-Rio](https://www.puc-rio.br/)) in Brazil since 1993 by:

- **Roberto Ierusalimschy** — Professor in the Department of Computer Science at PUC-Rio; head of [LabLua](https://www.lua.org/)
- **Waldemar Celes** — Professor in the Department of Computer Science at PUC-Rio; director of Tecgraf
- **Luiz Henrique de Figueiredo** — Researcher at [IMPA](https://impa.br/); former consultant at Tecgraf

We are grateful to them, to PUC-Rio, to LabLua, and to everyone who has supported Lua. The language, its semantics, its bytecode model, and its standard libraries are their work. Prolua reimplements that design in Zig as a Lua 5.4-compatible interpreter; it is not the official Lua implementation and is not affiliated with Lua.org or PUC-Rio.

Further information:

- Language home: <https://www.lua.org/>
- Authors: <https://www.lua.org/authors.html>
- License: <https://www.lua.org/copyright.html>
- Reference manual: <https://www.lua.org/manual/5.4/>

### Lua copyright notice

Lua is free software distributed under the MIT license. Lua is not in the public domain; PUC-Rio keeps its copyright. The Lua team asks that users give credit by including the following notice:

> Copyright © 1994–2026 Lua.org, PUC-Rio.
>
> Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:
>
> The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.
>
> THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

Prolua itself remains licensed under the terms in `LICENSE`. The notice above credits Lua.org and PUC-Rio for Lua.
