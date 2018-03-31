# Document Style

This chapter contains the style for writing design documentation.

## Paragraph
A paragraph is one continuous line of text. It shall not be broken at the 80 limit character.

**Rationale**: It limits the diff in git. If a paragraph is changed and the editor automatically reflowes the text the resulting diff is *more* than necessary which makes it harder to see what *really* changed.

## Rationale
It is important that REQ and SPC tag have a rationale explaining why the requirement is needed. It helps separate the background and reasoning from the requirement. The requirement can be kept to a oneliner while the rationale/why is more *colorful* and explanatary.

The requirement though shall be consistent with the rationale. A change to a requirement must take into consideration the rationale.

## Use Case
A use case must be read as a whole. This is a bit different from other requirements. The intention is that a use case should tell a *story*. Try to separate the condensed use case to a few sentences if possible if it is possible to keep the spirit.

The use case is inteded to convey the expected behavior of the *whole* feature. Of *all* requirements that are a result of it. The requirements linked to the use case should be *validated* that they fulfill the use case.

The validation is kind a separate from the verification.
 * Verification. Do the implementation fulfill the requirement?
 * Validation: Do the program *feel* good to use from the use case perspective?
