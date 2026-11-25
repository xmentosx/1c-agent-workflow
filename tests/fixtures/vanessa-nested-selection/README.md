# Selected nested Vanessa features

`filter.bsl` and `tree-builder.bsl` are unchanged excerpts of
`VanessaAutomation/Forms/УправляемаяФорма/Ext/Form/Module.bsl` from Pr-Mex's
Vanessa Automation commit `f3a01778a14d29b38204685deea0131274d438ff`
(tag `1.2.043.28`). The UTF-8 text of the complete module, with its BOM removed,
has SHA-256 `3e905824dac7db0afdee9fe51858fe2c7ce80d6a6bdda14978cb0f1c58b6de32`.
The upstream BSD license is retained in
`third-party/vanessa-automation/1.2.043.28-itl-r9/LICENSE.upstream`.
The scoped Git attributes preserve upstream LF and its original trailing
whitespace for these excerpts, as for the controlled upstream patch itself.

The regression executes the actual filter and tree-building BSL in OneScript.
The baseline removes directory entries while retaining file depths, making a
feature the parent of another feature. The Vanessa feature loader descends into
non-feature rows only, so those children do not reach loading. The candidate
changes the logical levels after filtering while preserving physical paths and
selection order. Fixtures retain mixed root/nested and deeper nested inputs.

This isolated algorithm regression does not replace a real combined run of the
original PM5 49-scenario layout or candidate EPF qualification.
