# BOOT-CRACKTRO R1PP3R

This program rips Atari ST
[cracktros](https://democyclopedia.wordpress.com/2019/03/26/c-for-cracktros/)
that are not in file form.

Some games do not use a file system and load their data from hard-coded
areas of the disk without TOS support.  
The cracktros used on these games are also stored directly on disk sectors
and loaded by the bootsector.

This program allows you to extract such a boot-cracktro in order to save
it as a standard PRG that is executable from the GEM.

This program has been developed to help the archivists
(such as [DEMOZOO](https://demozoo.org/groups/31491/))
in their work of indexing and preserving Atari ST cracktros.

Here is how it works:
- The disk containing the boot-cracktro to be ripped is inserted into
  drive A.
- A special execution environment, called a sandbox, is created.
  It allows the bootsector to be safely executed in low user memory
  as if it were running at boot time (without the GEM).
- The XBios vector is hooked to monitor disk access in order to detect
  the loading of the boot-cracktro.
- The bootsector is executed in the sandbox and the boot-cracktro is
  saved on-the-fly when loaded, into a safe area in high memory.
- Once the cracktro has been ripped, the original execution environment
  is restored (the sandbox is destroyed).
- The ripped cracktro is wrapped in a special code (called preamble)
  whose purpose is to make the cracktro executable from the GEM.
- A file-selector dialog box is opened to allow the ripped cracktro
  to be saved to disk.
- The cracktro is saved as a regular GEMDOS PRG file.

The *ripping* process is actually quite elaborate and clever.
For example:
- The protections used in some bootsectors can be detected and
  neutralized on-the-fly.
- The execution context of the cracktro set up by the bootsector,
  including the video configuration, is dumped so that it can be
  restored by the preamble code of the generated cracktro PRG.
- The lack of a boot-cracktro or the existence of regular files on
  the floppy disk is detected and handled smoothly.
- The generated cracktro PRGs can be run from the GEM desktop
  including from a hard disk, and under any TOS including EmuTOS.

For more information, all the interesting mechanisms and tricks are
explained in detail in the comments of the source code.

You can find in this repository:

- The *src/* directory which contains the *R1PP3R.S* source file, with plenty of explanations and comments.

- The *prebuilt/* directory which provides the *R1PP3R.PRG* executable for Atari ST.

---

*Orion of The Replicants - March 2021*
