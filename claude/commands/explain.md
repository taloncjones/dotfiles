# /explain - Deep dive explanation

Provide a thorough explanation of code, concepts, or architecture.

## Usage

- `/explain` - Explain the current file or recent context
- `/explain <file:function>` - Explain specific function
- `/explain <concept>` - Explain a concept in context of this codebase

## Instructions

1. **Identify the target:**
   - If a file/function specified, read it
   - If a concept, find relevant code examples in this codebase

2. **Provide layered explanation:**
   - **TL;DR** - One sentence summary
   - **What it does** - Functional description
   - **How it works** - Step-by-step walkthrough
   - **Why it's designed this way** - Design decisions, tradeoffs
   - **Key dependencies** - What it relies on, what relies on it

3. **Use concrete examples:**
   - Reference actual line numbers
   - Show data flow with real variable names
   - Include example inputs/outputs if applicable

4. **Keep it scannable:**
   - Use headers and bullets
   - Code snippets for key parts
   - Diagrams in ASCII if helpful for data flow
