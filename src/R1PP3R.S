***************************************************************************
*
* BOOT-CRACKTRO R1PP3R v1.0, March 2021.
* By Orion of The Replicants
*
* This program rips Atari ST cracktros that are not in file form.
*
* Some games do not use a file system and load their data from hard-coded
* areas of the disk without TOS support. The cracktros used on these games
* are also stored directly on disk sectors and loaded by the bootsector.
*
* This program allows you to extract such a boot-cracktro in order to save
* it as a standard PRG that is executable from the GEM.
*
* This program has been developed to help the archivists (such as demozoo)
* in their work of indexing and preserving Atari ST cracktros.
*
* Here is how it works:
* - The disk containing the boot-cracktro to be ripped is inserted into
*   drive A.
* - A special execution environment, called a sandbox, is created.
*   It allows the bootsector to be safely executed in low user memory
*   as if it were running at boot time (without the GEM).
* - The XBios vector is hooked to monitor disk access in order to detect
*   the loading of the boot-cracktro.
* - The bootsector is executed in the sandbox and the boot-cracktro is
*   saved on-the-fly when loaded, into a safe area in high memory.
* - Once the cracktro has been ripped, the original execution environment
*   is restored (the sandbox is destroyed).
* - The ripped cracktro is wrapped in a special code (called preamble)
*   whose purpose is to make the cracktro executable from the GEM.
* - A file-selector dialog box is opened to allow the ripped cracktro
*   to be saved to disk.
* - The cracktro is saved as a regular GEMDOS PRG file.
*
* The "ripping" process is actually quite elaborate and clever.
* For example:
* - The protections used in some bootsectors can be detected and
*   neutralized on-the-fly.
* - The execution context of the cracktro set up by the bootsector,
*   including the video configuration, is dumped so that it can be
*   restored by the preamble code of the generated cracktro PRG.
* - The lack of a boot-cracktro or the existence of regular files on
*   the floppy disk is detected and handled smoothly.
* - The generated cracktro PRGs can be run from the GEM desktop
*   including from a hard disk, and under any TOS including EmuTOS.
*
* For more information, all the interesting mechanisms and tricks are
* explained in detail in the comments of this source code.
*
* Limitations of this program:
* The "ripping" process only works under the following conditions:
* - It is necessary that the cracktro can be saved as a self-contained
*   binary. To this end, the cracktro must be loaded as a contiguous
*   block of memory although it can be loaded from arbitrary sectors.
* - The cracktro must be loaded using the TOS services, i.e. either
*   the Floprd function of the XBios or the Rwabs function of the Bios.
* - The loading address and the execution address of the cracktro must
*   be the same.
*
* Practical tests have shown that about 90% of the boot-cracktros can
* be automatically ripped by this program.
*
* Limitation of the filed cracktros:
* The generated cracktro PRGs cannot quit and return to the GEM desktop.
* Once the cracktro is running, you must reset the machine to return
* to the GEM desktop.
*
* Requirements:
* - This program runs on all Atari ST(e) machines (all TOS versions).
* - It requires 1MB of RAM.
* - It can run either in low or medium resolution.
* - The ripped cracktros run on all Atari ST(e) machines with 512KB
*   of RAM (all TOS versions), and possibly from a hard-disk.
*
* Versions history:
*
* - v1.0, March 2021, initial version.
*
* Git repository: https://github.com/orionfuzion/r1pp3r
* Contact:        orion.replicants@gmail.com or orion.fuzion@gmail.com
*
* This ASM source file should be assembled using Devpac Developer
* (GenST) v2.23 as an executable program named 'R1PP3R.PRG'.
*
***************************************************************************

STACK_SIZE          =	1024            ; 1 KB
INTRO_BUF_SIZE      =	$40000          ; 256 KB
BOOT_TIMEOUT        =	5               ; Seconds

DEBUG               =	0               ; 0 or 1
DBG_SAFE_TIMERC     =	(DEBUG&0)       ; 0 or 1
DBG_BOOT_ANALYSIS   =	(DEBUG&1)       ; 0 or 1
DBG_SELFTESTS       =	(DEBUG&1)       ; 0 or 1

	;
	; - Turn all optimizations on
	; - Force position-independent code
	; - Case insensitive labels
	; - Use periods for local labels 
	;
	opt	o+,p+,c-,U-

	section	text

	;
	; Main entry point.
	;
pt_base:
	; Save the basepage (process descriptor).
	lea	basepage(pc),a0
	move.l	4(a7),(a0)

	; Save the start address of the program.
	lea	pt_base_orig(pc),a1
	lea	pt_base(pc),a0
	move.l	a0,(a1)

	; Line-A Initialization (for mouse hide/show).
	bsr	linea_init
	tst.l	d0
	bne.s	.hidem
	lea	txt_linea_err(pc),a0
	bra	.fatal

	; Hide the mouse and clear the screen.
.hidem	bsr	linea_hidemouse
	bsr	cls

	; Check the machine type.
	; Only ST-compatible machines are supported.
	; This includes: ST, STe and MegaSTe.
.chkmch	lea	get_mch_type(pc),a0
	bsr	supexec
	cmpi.w	#MCH_MEGASTE,d0
	bls.s	.chkrez
	lea	txt_mch_err(pc),a0
	bra	.fatal

	; Check the current screen resolution.
	; Only Low and Medium resolutions are supported.
.chkrez	bsr	getrez
	cmpi.w	#1,d0
	bls.s	.chkmem
	lea	txt_rez_err(pc),a0
	bra	.fatal

	; Check if there is enough memory for our needs.
	; Also determine the areas in high-memory (above $80000)
	; where the current program will be moved and where the
	; low memory and ripped cracktro will be saved.
.chkmem	lea	check_mem(pc),a0
	bsr	supexec
	tst.l	d0
	beq.s	.chkvec
.errmem	lea	txt_mem_err(pc),a0
	bra	.fatal

	; Check if some critical exception vectors have handlers
	; running in low memory (below $80000).
.chkvec	lea	check_vecs(pc),a0
	bsr	supexec
	tst.l	d0
	beq.s	.mtrim
	lea	txt_vecs_err(pc),a0
	bra	.fatal

	; Get the basepage address and adjust (shrink) the memory
	; allocated to this program according to the information
	; determined by check_mem().
.mtrim	movea.l	basepage(pc),a0
	move.l	prog_memtop(pc),d0
	sub.l	a0,d0
	bsr	mshrink
	tst.l	d0
	bne.s	.errmem

	; Move this program to high memory and continue execution
	; from this new location.
.reloc	bsr	reloc_prog
	jmp	(.reljmp-pt_base)(a0)
.reljmp
	; Set up the stack.
	lea	stack_top(pc),a7

	; Initialize the AES (needed for the file-selector).
	bsr	aes_appl_init
	tst.l	d0
	bpl.s	.sinit
	lea	txt_aes_err(pc),a0
	bra.s	.fatal

	; Perform the initialization that requires
	; supervisor privileges.
.sinit	lea	init_sup(pc),a0
	bsr	supexec

	; Print the main menu and wait for a keystroke.
.main	bsr	main_menu

	pea	.main(pc)  ; Return address
	cmpi.b	#KEY_RIP,d0
	beq	rip        ; Rip a boot-cracktro
	cmpi.b	#KEY_HELP,d0
	beq	help       ; Print the help message
	cmpi.b	#KEY_CREDITS,d0
	beq	credits    ; Print the credits message
	cmpi.b	#KEY_GREETS,d0
	beq	greetings  ; Print the greetings message
	ifne	DBG_BOOT_ANALYSIS
	cmpi.b	#KEY_ANALYZE,d0
	beq	analyze    ; Analyze the boot (debug)
	endc	; DBG_BOOT_ANALYSIS
	ifne	DBG_SELFTESTS
	cmpi.b	#KEY_TESTS,d0
	beq	selftests  ; Self-tests (debug)
	endc	; DBG_SELFTESTS

	; Key KEY_EXIT.
	addq.l	#4,a7

	; De-init path.
.quit	
	; Free the buffer used to load regular files.
	bsr	buf_free

	; Perform the de-initialization that requires
	; supervisor privileges.
	lea	deinit_sup(pc),a0
	bsr	supexec

	; Unregister the program from the AES.
	bsr	aes_appl_exit

	; Show the mouse.
	bsr	linea_showmouse

	; Return to the original program location.
	movea.l	pt_base_orig(pc),a0
	jmp	(.retjmp-pt_base)(a0)
.retjmp
	; Set up the stack in the original BSS location.
	lea	(stack_top-pt_base)(a0),a7

	; Before exiting, shrink the memory to the minimum size
	; used by the program.
	; This is required on TOS 1.00 and 1.02 which do not
	; free the program memory when pterm0 is called.
	lea	(pt_end-pt_base)(a0),a0
	move.l	a0,d0
	movea.l	basepage(pc),a0
	sub.l	a0,d0
	bsr.s	mshrink

	; Terminate the program.
.pterm0	clr.w	-(a7)
	trap	#1

	; A fatal error occurred during initialization:
	; print an error message and wait for a keystroke
	; before terminating the program.
.fatal	bsr.s	print
	lea	txt_fatal_exit(pc),a0
	bsr.s	print
	bsr.s	readchar
	bra.s	.quit

	;
	; mshrink()
	;
	; Reduce already reserved memory.
	;
	; In:
	;   d0: new size
	;   a0: start address
	;
	; Out:
	;   d0: GEMDOS error
	;
mshrink:
	movem.l	d1-d2/a0-a2,-(a7)

	move.l	d0,-(a7)
	pea	(a0)
	move.l	#$4a0000,-(a7)
	trap	#1
	lea	12(a7),a7

	movem.l	(a7)+,d1-d2/a0-a2
	rts

	;
	; malloc()
	;
	; Allocate a block of memory.
	;
	; In:
	;   d0: number of bytes to be allocated
	;
	; Out:
	;   d0: address of the allocated block,
	;       or NULL if not enough memory
	;
malloc:
	movem.l	d1-d2/a0-a2,-(a7)

	move.l	d0,-(a7)
	move.w	#$48,-(a7)
	trap	#1
	addq.l	#6,a7	

	movem.l	(a7)+,d1-d2/a0-a2
	rts

	;
	; mfree()
	;
	; Free the memory block previously allocated by malloc.
	;
	; In:
	;   a0: address of the block to be freed
	;
mfree:
	movem.l	d0-d2/a0-a2,-(a7)

	pea	(a0)
	move.w	#$49,-(a7)
	trap	#1
	addq.l	#6,a7	

	movem.l	(a7)+,d0-d2/a0-a2
	rts

	;
	; print()
	;
	; Write a string to the standard output device (Cconws).
	;
	; In:
	;   a0: string address
	;
print:
	movem.l	d0-d2/a0-a2,-(a7)

	pea	(a0)
	move.w	#9,-(a7)
	trap	#1
	addq.l	#6,a7	

	movem.l	(a7)+,d0-d2/a0-a2
	rts

	;
	; readchar()
	;
	; Read a character from the standard input device (Crawcin).
	;
	; Out:
	;   d0: key ASCII code
	;
readchar:
	movem.l	d1-d2/a0-a2,-(a7)

	move.w	#7,-(a7)
	trap	#1
	addq.l	#2,a7

	movem.l	(a7)+,d1-d2/a0-a2
	rts

	;
	; fgetdta()
	;
	; Get the address of the DTA struct (Disk Transfer Address).
	;
	; Out:
	;   d0: DTA struct address
	;
fgetdta:
	movem.l	d1-d2/a0-a2,-(a7)

	move.w	#47,-(a7)
	trap	#1
	addq.l	#2,a7

	movem.l	(a7)+,d1-d2/a0-a2
	rts

	;
	; fsfirst()
	;
	; Search for first file entry.
	;
	; In:
	;   d0: requested file attributes
	;   a0: filename or access path (may contain wildcards)
	;
	; Out:
	;   d0: 0 if the requested filename was found,
	;       a GEMDOS error otherwise
	;
fsfirst:
	movem.l	d1-d2/a0-a2,-(a7)

	move.w	d0,-(a7)
	pea	(a0)
	move.w	#78,-(a7)
	trap	#1
	addq.l	#8,a7

	movem.l	(a7)+,d1-d2/a0-a2
	rts

	;
	; fopen()
	;
	; Open a file.
	;
	; In:
	;   a0: filename
	;
	; Out:
	;   d0: file handle or GEMDOS error
	;
fopen:
	movem.l	d1-d2/a0-a2,-(a7)

	clr.w	-(a7)
	pea	(a0)
	move.w	#$3d,-(a7)
	trap	#1
	addq.l	#8,a7

	movem.l	(a7)+,d1-d2/a0-a2
	rts

	;
	; fcreate()
	;
	; Create a file.
	;
	; In:
	;   a0: filename
	;
	; Out:
	;   d0: file handle or GEMDOS error
	;
fcreate:
	movem.l	d1-d2/a0-a2,-(a7)

	clr.w	-(a7)
	pea	(a0)
	move.w	#$3c,-(a7)
	trap	#1
	addq.l	#8,a7

	movem.l	(a7)+,d1-d2/a0-a2
	rts

	;
	; fread()
	;
	; Read from a file.
	;
	; In:
	;   d0: file handle
	;   d1: number of bytes of data to read
	;   a0: address of the receiving buffer
	;
	; Out:
	;   d0: number of bytes actually read or GEMDOS error
	;
fread:
	movem.l	d1-d2/a0-a2,-(a7)

	pea	(a0)
	move.l	d1,-(a7)
	move.w	d0,-(a7)
	move.w	#$3f,-(a7)
	trap	#1
	lea	12(a7),a7

	movem.l	(a7)+,d1-d2/a0-a2
	rts

	;
	; fwrite()
	;
	; Write to a file.
	;
	; In:
	;   d0: file handle
	;   d1: number of bytes to be written
	;   a0: address of the buffer containing the data
	;
	; Out:
	;   d0: number of bytes actually written or GEMDOS error
	;
fwrite:
	movem.l	d1-d2/a0-a2,-(a7)

	pea	(a0)
	move.l	d1,-(a7)
	move.w	d0,-(a7)
	move.w	#$40,-(a7)
	trap	#1
	lea	12(a7),a7

	movem.l	(a7)+,d1-d2/a0-a2
	rts

	;
	; fclose()
	;
	; Close a file.
	;
	; In:
	;   d0: file handle
	;
	; Out:
	;   d0: GEMDOS error
	;
fclose:
	movem.l	d1-d2/a0-a2,-(a7)

	; Valid file handle?
	tst.l	d0
	bmi.s	.ret

	move.w	d0,-(a7)
	move.w	#$3e,-(a7)
	trap	#1
	addq.l	#4,a7

.ret	movem.l	(a7)+,d1-d2/a0-a2
	rts

	;
	; getbpb()
	;
	; Get the Bios Parameter Block and reset the media-change
	; status of the Bios.
	;
	; In:
	;   d0: drive number
	;
	; Out:
	;   d0: address of the Bios Parameter Block
	;
getbpb:
	movem.l	d1-d2/a0-a2,-(a7)

	move.w	d0,-(a7)
	move.w	#7,-(a7)
	trap	#13
	addq.l	#4,a7

	movem.l	(a7)+,d1-d2/a0-a2
	rts

	;
	; supexec()
	;
	; Execute a routine in supervisor mode.
	;
	; In:
	;   a0: routine address
	;   All registers are passed unmodified to the routine
	;
	; Out:
	;   d0: return value of the routine
	;
supexec:
	movem.l	d0-a6,-(a7)

	lea	supexec_trampoline(pc),a1
	move.l	a7,4(a1)

	pea	(a1)
	move.w	#$26,-(a7)
	trap	#14
	lea	(6+4)(a7),a7    ; Don't restore d0

	movem.l	(a7)+,d1-a6
	rts

supexec_trampoline:
	movem.l	$0.l,d0-a6
	jmp	(a0)

	;
	; getrez()
	;
	; Return current screen resolution code.
	;
	; Out:
	;   d0: resolution code
	;
getrez:
	movem.l	d1-d2/a0-a2,-(a7)

	move.w	#$4,-(a7)
	trap	#14
	addq.l	#2,a7

	movem.l	(a7)+,d1-d2/a0-a2
	rts

	;
	; vsync()
	;
	; Wait for the next vertical sync signal.
	;
vsync:
	movem.l	d0-d2/a0-a2,-(a7)

	move.w	#$25,-(a7)
	trap	#14
	addq.l	#2,a7

	movem.l	(a7)+,d0-d2/a0-a2
	rts

	;
	; linea_init()
	;
	; Line-A initialization.
	;
	; Out:
	;   d0: Line-A intin pointer, or 0 in case of error
	;
	;   Note: The pointer to the Line-A parameter block
	;         is saved internally
	;
linea_init:
	movem.l	d1-d2/a0-a2,-(a7)

	dc.w	$a000
	move.l	a0,d0
	beq.s	.ret
	move.l	8(a0),d0
	beq.s	.ret

	lea	linea_param_blk(pc),a1
	move.l	a0,(a1)

.ret	movem.l	(a7)+,d1-d2/a0-a2
	rts

	;
	; linea_hidemouse()
	;
	; Line-A hide mouse.
	;
linea_hidemouse:
	movem.l	d0-d2/a0-a2,-(a7)

	move.l	linea_param_blk(pc),d0
	beq.s	.ret

	dc.w	$a00a           ; Hide mouse

.ret	movem.l	(a7)+,d0-d2/a0-a2
	rts

	;
	; linea_showmouse()
	;
	; Line-A show mouse.
	;
	; Note: the mouse pointer is switched on immediately
	;
linea_showmouse:
	movem.l	d0-d2/a0-a2,-(a7)

	move.l	linea_param_blk(pc),d0
	beq.s	.ret

	movea.l	d0,a0           ; Line-A param block
	movea.l	8(a0),a1        ; Line-A intin
	clr.w	(a1)            ; Mouse shown immediately
	dc.w	$a009           ; Show mouse

.ret	movem.l	(a7)+,d0-d2/a0-a2
	rts

	;
	; aes_call()
	;
	; Perform an AES call.
	;
	; Out:
	;   d0: the 16-bit value returned by the AES in intout[0]
	;       sign-extended to 32-bits
	;
aes_call:
	movem.l	d1-d2/a0-a2,-(a7)

	lea	aes_pb(pc),a0
	move.l	a0,d1           ; Parameter block
	move.l	#200,d0         ; AES opcode
	trap	#2              ; Call GEM
	move.w	aes_intout(pc),d0
	ext.l	d0              ; intout[0]

	movem.l	(a7)+,d1-d2/a0-a2
	rts

	;
	; aes_params_reset()
	;
	; Reset AES parameters to zero.
	; It includes:
	; - control  ( 5 words)
	; - intin    (16 words)
	; - intout   (16 words)
	; - addrin   (16 long words)
	; - addrout  (16 long words)
	;
aes_params_reset:
	movem.l	d0/a0,-(a7)

	lea	aes_control(pc),a0
	move.w	#(aes_params_end-aes_control)/2-1,d0
.clear	clr.w	(a0)+
	dbf	d0,.clear

	movem.l	(a7)+,d0/a0
	rts

	;
	; aes_appl_init()
	;
	; Register the application under AES.
	;
	; Out:
	;   d0: ID of the application, or -1 in case of error
	;
aes_appl_init:
	movem.l	d1/a0,-(a7)

	; Relocate addresses of the AES parameter block.
	lea	aes_pb(pc),a0
	move.l	a0,d1
	moveq.l	#(aes_pb_end-aes_pb)/4-1,d0
.reloc	add.l	d1,(a0)+
	dbf	d0,.reloc

	bsr.s	aes_params_reset

	lea	aes_control(pc),a0
	move.w	#10,(a0)        ; opcode: appl_init
	move.w	#1,4(a0)        ; intout: return value
	; intout[0] = -1 (error).
	move.w	#-1,(aes_intout-aes_control)(a0)

	bsr.s	aes_call
	; Check that global[0] contains the AES version.
	move.w	aes_global(pc),d1
	beq.s	.err
	; Check the return value of the AES call (intout[0]).
	tst.l	d0
	bmi.s	.err

	; Initialization done.
	lea	aes_initdone(pc),a0
	st.b	(a0)

.ret	movem.l	(a7)+,d1/a0
	rts
.err	moveq.l	#-1,d0
	bra.s	.ret

	;
	; aes_appl_exit()
	;
	; Deregister the application from the AES.
	;
aes_appl_exit:
	movem.l	d0/a0,-(a7)

	; Do not call appl_exit if the registration was not
	; done or failed.
	move.w	aes_initdone(pc),d0
	beq.s	.ret

	bsr.s	aes_params_reset

	lea	aes_control(pc),a0
	move.w	#19,(a0)        ; opcode: appl_exit
	move.w	#1,4(a0)        ; intout: return value

	bsr	aes_call

.ret	movem.l	(a7)+,d0/a0
	rts

	;
	; aes_fsel_input()
	;
	; Open a file-selector dialog box.
	;
	; In:
	;   d0: if !0, first clear the default filename of the 
	;       file-selector (fsel_file)
	;   a0: buffer containing the default access path of the
	;       file-selector with appended search mask;
	;       must be large enough to contain the absolute path
	;       of the selected directory returned by the AES
	;       fsel_input call
	;   fsel_file: buffer containing the default filename
	;              of the file-selector
	;
	; Out:
	;   d0: !0 if a filename was selected, or 0 if no filename
	;       was selected or if an error occurred
	;   a0: the default access path is replaced with the
	;       absolute path of the selected directory
	;   fsel_file: the default filename is replaced with the
	;              selected filename
	;
aes_fsel_input:
	movem.l	d1-d2/a0-a2,-(a7)

	bsr	aes_params_reset

	lea	aes_control(pc),a2
	move.w	#90,(a2)        ; opcode: fsel_input
	move.w	#2,4(a2)        ; intout: fs_ireturn, fs_iexbutton
	move.w	#2,6(a2)        ; addrin: fs_iinpath, fs_iinsel

	; Default access path (after the call, contains
	; the absolute path of the selected directory).
	move.l	a0,(aes_addrin-aes_control)(a2)

	; Default filename (after the call, contains
	; the selected filename).
	lea	fsel_file(pc),a0
	move.l	a0,(aes_addrin-aes_control+4)(a2)

	; Clear the default filename if requested.
	tst.w	d0
	beq.s	.call
	moveq.l	#15,d0
.clear	clr.b	(a0)+
	dbf	d0,.clear

.call	bsr	aes_call

	tst.l	d0                    ; Call error?
	beq.s	.ret
	move.w	aes_intout+2(pc),d1   ; Cancel button?
	beq.s	.err
	move.b	fsel_file(pc),d1      ; Empty filename?
	beq.s	.err

.ret	movem.l	(a7)+,d1-d2/a0-a2
	rts
.err	moveq.l	#0,d0
	bra.s	.ret

	;
	; mcopy()
	;
	; Copy a memory area.
	;
	; in:
	;   d0: number of bytes to copy
	;   a0: memory area source 
	;   a1: memory area destination
	;
mcopy:
	movem.l	d0-d1/a0-a1,-(a7)

	cmpi.l	#32,d0
	blo.s	.cp_1
	move.l	a0,d1
	btst	#0,d1
	beq.s	.src_ok
	move.b	(a0)+,(a1)+
	subq.l	#1,d0
	move.l	a0,d1

.src_ok	add.l	a1,d1
	btst	#0,d1
	bne.s	.cp_1
	move.l	d0,d1
	andi.l	#31,d0
	asr.l	#5,d1
	beq.s	.cp_4

	movem.l	d2-d7/a2-a3,-(a7)
.lp_32	movem.l	(a0)+,d2-d7/a2-a3
	movem.l	d2-d7/a2-a3,(a1)
	lea	32(a1),a1
	subq.l	#1,d1
	bne.s	.lp_32
	movem.l	(a7)+,d2-d7/a2-a3

.cp_4	move.l	d0,d1
	andi.l	#3,d0
	asr.l	#2,d1
	beq.s	.cp_1

.lp_4	move.l	(a0)+,(a1)+
	subq.l	#1,d1
	bne.s	.lp_4

.cp_1	tst.l	d0
	beq.s	.end

.lp_1	move.b	(a0)+,(a1)+
	subq.l	#1,d0
	bne.s	.lp_1

.end	movem.l	(a7)+,d0-d1/a0-a1
	rts

	;
	; cls()
	;
	; Clear the screen.
	;
cls:
	move.l	a0,-(a7)
	lea	txt_cls(pc),a0
	bsr	print
	movea.l	(a7)+,a0
	rts

	; Machine types.
MCH_ST         =	$1
MCH_STE        =	$2
MCH_MEGASTE    =	$3
MCH_TT         =	$4
MCH_FALCON     =	$5
MCH_CT60_BIT   =	8
MCH_CT60       =	(1<<MCH_CT60_BIT)

	;
	; get_mch_type()
	;
	; Walk through the cookie jar table to determine the
	; current machine type: ST/STe/MegaSTe/TT/Falcon/CT60.
	;
	; Called from supexec.
	;
	; Out:
	;   d0: machine type
	;
get_mch_type:
	moveq.l	#0,d0

	; Get a pointer to the OSHEADER (SYSHDR) structure.
	movea.l	$4f2.w,a0

	; Get TOS version number.
	move.w	2(a0),d1
	; Old TOSes don't provide the cookie jar,
	; assume machine is ST in that case.
	cmpi.w	#$106,d1
	blo.s	.dflt

	; Get a pointer to the cookie jar table.
	move.l	$5a0.w,d1
	beq.s	.dflt
	movea.l	d1,a0

.loop	move.l	(a0)+,d1
	beq.s	.dflt
	cmpi.l	#'_MCH',d1
	beq.s	.found
	cmpi.l	#'CT60',d1      ; CT60
	bne.s	.next
	ori.w	#MCH_CT60,d0
.next	addq.l	#4,a0
	bra.s	.loop

.found	move.w	(a0)+,d1
	cmpi.w	#1,d1           ; STe
	bne.s	.tst_tt
	btst.b	#4,1(a0)        ; MegaSTe
	bne.s	.mste
	move.b	#MCH_STE,d0
	bra.s	.end

.mste	move.b	#MCH_MEGASTE,d0
	bra.s	.end

.tst_tt	cmpi.w	#2,d1           ; TT
	bne.s	.tst_falcon
	move.b	#MCH_TT,d0
	bra.s	.end

.tst_falcon
	cmpi.w	#3,d1           ; Falcon
	bne.s	.dflt
	move.b	#MCH_FALCON,d0
	bra.s	.end

.dflt	move.b	#MCH_ST,d0	; Default/ST
.end	rts

	;
	; check_mem()
	;
	; Check if there is enough high memory (above $80000) and
	; determine the areas in high memory where:
	; 1. The current program is moved.
	; 2. The low memory is saved, so that it can be restored
	;    after the cracktro has been ripped.
	;    If the program is started in low user memory (between
	;    _membot and $80000), only the program and the memory
	;    below it are saved.
	;    If the program is started in high memory, the entire
	;    low memory (below $80000) is saved.
	;    Indeed, the memory above the program is considered
	;    free and the memory above $80000 is not supposed to
	;    be touched by the bootsector or the cracktro.
	; 3. The ripped cracktro is saved.
	;
	; The low user memory (between _membot and $80000) is
	; fully allocated to the bootsector to load and execute
	; the cracktro that must be ripped.
	;
	; The current program is not moved if it is already
	; executing in high memory.
	;
	; The memory is organized as follows:
	;
	;   +--------------------+ $0 - Low memory
	;   |    System Vars     |
	;   +--------------------+ _membot - Low user memory
	;   |                    |
	;   |     Bootsector     |
	;   |         +          | Sandbox
	;   |      Cracktro      |
	;   |                    |
	;   +--------------------+ $80000 - High memory
	;   :                    :
	;   +--------------------+ pt_base_rel ($80400 or in place)
	;   |    This Program    |
	;   +--------------------+ intro_buf_rel [256 KB]
	;   |  Ripped Cracktro   |
	;   +--------------------+ lowmem_buf_rel [lowmem_size]
	;   |  Saved Low Memory  |
	;   +--------------------+ prog_memtop
	;   |                    |
	;   :    Free Memory     :
	;   :                    :
	;
	; This routine is called from supexec.
	;
	; Out:
	;   d0: 0 if there is enough memory, -1 otherwise
	;   pt_base_rel: the address where the program is moved
	;   intro_buf_rel: the address where the cracktro is saved
	;   lowmem_buf_rel: the address where the low memory is
	;                   saved
	;   lowmem_size: the size of the low memory that needs
	;                to be saved
	;   prog_memtop: the highest address used by the program
	;                (used when calling mshrink)
	;
check_mem:
	; Check whether the program shall be moved in high memory
	; or can be executed in place (if already in high memory).
	lea	pt_base(pc),a0
	lea	$80000+STACK_SIZE,a1
	cmpa.l	a1,a0
	bhi.s	.pt_end
	exg.l	a0,a1
	adda.l	#(pt_end-pt_base),a1
.pt_end	lea	(intro_buf-pt_base)(a0),a2
	;
	; a0 = address where the program is moved
	; a1 = top address of the low memory to be saved
	; a2 = address where the cracktro is saved
	;
	lea	pt_base_rel(pc),a3
	move.l	a0,(a3)
	lea	intro_buf_rel(pc),a3
	move.l	a2,(a3)
	adda.l	#INTRO_BUF_SIZE+512,a2
	lea	lowmem_buf_rel(pc),a3
	move.l	a2,(a3)
	subq.l	#8,a1
	lea	lowmem_size(pc),a3
	move.l	a1,(a3)
	adda.l	a1,a2
	lea	512(a2),a2
	lea	prog_memtop(pc),a3
	move.l	a2,(a3)

	; a2 = highest address used by the program.
	; Check if it fits in the RAM available on
	; this machine.
	cmpa.l	$436.w,a2
	bls.s	.ok
	moveq.l	#-1,d0
	bra.s	.ret

.ok	moveq.l	#0,d0
.ret	rts

	;
	; check_vecs()
	;
	; Check if some critical exception vectors have handlers
	; running in low memory (below $80000).
	; If it is the case, this program cannot run because the
	; low user memory (between _membot and $80000) is fully
	; allocated to the bootsector to load and execute the
	; cracktro to be ripped.
	; Critical vectors (required by the system) are:
	; - VBL
	; - Timer C
	; - IKBD/ACIA
	; - Trap #1
	; - Trap #13
	; - Trap #14
	;
	; Called from supexec.
	;
	; Out:
	;   d0: 0 if all critical vectors have handlers running
	;       in high memory or in ROM, -1 otherwise
	;
check_vecs:
	move.l	#$80000,d0
	cmp.l	$70.w,d0        ; VBL
	bhs.s	.err
	ifeq	DBG_SAFE_TIMERC
	cmp.l	$114.w,d0       ; Timer C
	bhs.s	.err
	endc
	cmp.l	$118.w,d0       ; IKBD/ACIA
	bhs.s	.err
	cmp.l	$84.w,d0        ; Trap #1
	bhs.s	.err
	cmp.l	$b4.w,d0        ; Trap #13
	bhs.s	.err
	cmp.l	$b8.w,d0        ; Trap #14
	bhs.s	.err
	moveq.l	#0,d0
	rts
.err	moveq.l	#-1,d0
	rts

	;
	; reloc_prog()
	;
	; Move the current program to the location in high memory
	; determined by the check_mem() routine.
	;
	; Also copy the preamble code that wraps the ripped
	; cracktro to make it executable from the GEM.
	; That preamble code is copied in the data, right before
	; the buffer where the ripped cracktro is to be saved.
	;
	; Out:
	;   a0: the program entry point in high memory
	;       (new pt_base)
	;
reloc_prog:
	movem.l	d0/a1,-(a7)

	; Copy the preamble code before the buffer where the
	; ripped cracktro is to be saved.
	lea	intro_header(pc),a0
	lea	intro_header_dest(pc),a1
	move.w	#(intro_preamble_end-intro_header)/2-1,d0
.cp1	move.w	(a0)+,(a1)+
	dbf	d0,.cp1

	; Move the current program in high memory.
	lea	intro_buf(pc),a0
	movea.l	intro_buf_rel(pc),a1
	move.w	#(intro_buf-pt_base)/(4*4),d0
.cp2	move.l	-(a0),-(a1)
	move.l	-(a0),-(a1)
	move.l	-(a0),-(a1)
	move.l	-(a0),-(a1)
	dbf	d0,.cp2

	; Return the new entry point in a0.
	lea	((((intro_buf-pt_base)/(4*4)+1)*(4*4))-(intro_buf-pt_base))(a1),a0

	movem.l	(a7)+,d0/a1
	rts

	;
	; init_sup()
	;
	; Perform the initialization that requires
	; supervisor privileges:
	; - Save and init conterm (disable "Key repeat")
	; - Save the _dskbufp pointer
	; - Hook the hdv_bpb vector (to force media change
	;   detection)
	; - Hook the hdv_mediach vector (to force media change
	;   detection)
	; - Determine the destination drive where ripped files
	;   will be saved: the first Hard Drive is selected if
	;   it exists, Drive A is selected otherwise
	;
	; Called from supexec.
	;
	; Out:
	;   d0: 0
	;
init_sup:
	; Save conterm, disable "Key repeat".
	lea	conterm_saved(pc),a0
	move.b	$484.w,(a0)
	bclr.b	#1,$484.w

	; Save _dskbufp.
	lea	_dskbufp(pc),a0
	move.l	$4c6.w,(a0)

	; Hook the hdv_bpb vector.
	lea	getbpb_hook(pc),a0
	move.l	$472.w,(getbpb_orig+2-getbpb_hook)(a0)
	move.l	a0,$472.w

	; Hook the hdv_mediach vector.
	lea	mediach_hook(pc),a0
	move.l	$47e.w,(mediach_orig+2-mediach_hook)(a0)
	move.l	a0,$47e.w

	; Determine the destination drive where ripped files
	; will be saved.
	move.l	$4c2.w,d0
	lea	_drvbits(pc),a0
	move.l	d0,(a0)
	moveq.l	#0,d1           ; 0=A, 1=B
	andi.l	#$fffffffc,d0
	beq.s	.hbit
.tstbit	addq.l	#1,d1
	btst	d1,d0
	beq.s	.tstbit
.hbit	addi.b	#'A',d1
	lea	path_drv_dest(pc),a0
	move.b	d1,(a0)

	moveq.l	#0,d0
	rts

	;
	; deinit_sup()
	;
	; Perform the de-initialization that requires
	; supervisor privileges:
	; - Restore conterm
	; - Restore original hdv_bpb and hdv_mediach vectors
	;
	; Called from supexec.
	;
	; Out:
	;   d0: 0
	;
deinit_sup:
	; Perform the de-init only if the init was done.
	move.l	_dskbufp(pc),d0
	beq.s	.ret
	move.b	conterm_saved(pc),$484.w
	move.l	getbpb_orig+2(pc),$472.w
	move.l	mediach_orig+2(pc),$47e.w
	moveq.l	#0,d0
.ret	rts

	;
	; main_menu()
	;
	; Display the main menu, wait for a menu option to be
	; selected and return the corresponding key pressed.
	;
	; Out:
	;   d0: ASCII code of the key pressed
	;
main_menu:
	move.l	a0,-(a7)

.again	lea	txt_title(pc),a0
	bsr	print
	lea	txt_main(pc),a0
	bsr	print
.wkey	bsr	readchar
	bsr	cls
	cmpi.b	#'1',d0
	blo.s	.again
	cmpi.b	#'5'+DBG_SELFTESTS+DBG_BOOT_ANALYSIS,d0
	bhi.s	.again

	movea.l	(a7)+,a0
	rts

	;
	; help()
	;
	; Print the help message.
	;
	; This routine is called by the main menu when the
	; option "Help" is selected.
	;
help:
	move.l	a0,-(a7)

	lea	txt_title(pc),a0
	bsr	print
	lea	txt_help(pc),a0
	bsr	print
	lea	txt_return_main(pc),a0
	bsr	print
	bsr	readchar

	movea.l	(a7)+,a0
	rts

	;
	; credits()
	;
	; Print the credits message.
	;
	; This routine is called by the main menu when the
	; option "Credits" is selected.
	;
credits:
	move.l	a0,-(a7)

	lea	txt_title(pc),a0
	bsr	print
	lea	txt_credits(pc),a0
	bsr	print
	lea	txt_return_main(pc),a0
	bsr	print
	bsr	readchar

	movea.l	(a7)+,a0
	rts

	;
	; greetings()
	;
	; Print the greetings message.
	;
	; This routine is called by the main menu when the
	; option "Greetings" is selected.
	;
greetings:
	move.l	a0,-(a7)

	lea	txt_title(pc),a0
	bsr	print
	lea	txt_greetings(pc),a0
	bsr	print
	lea	txt_return_main(pc),a0
	bsr	print
	bsr	readchar

	movea.l	(a7)+,a0
	rts

	;
	; file_select()
	;
	; Open a file-selector dialog box and return the absolute
	; path (directories + filename) of the selected file.
	;
	; In:
	;   d0: if !0, first clear the default filename of the 
	;       file-selector (fsel_file)
	;   a0: buffer containing the default access path of the
	;       file-selector with appended search mask;
	;       must be large enough to contain the absolute path
	;       of the selected directory returned by the AES
	;       fsel_input call
	;   fsel_file: buffer containing the default filename
	;              of the file-selector
	;
	; Out:
	;   d0: 0 if a filename was selected, or -1 if no filename
	;       was selected or if an error occurred
	;   a0: pointer to the absolute path of the selected file,
	;       or 0 if no filename was selected or if an error
	;       occurred
	;   The default access path (given as input parameter)
	;   is replaced with the absolute path of the selected
	;   directory, the default filename (fsel_file) is
	;   replaced with the selected filename
	;
file_select:
	movem.l	d1/a1-a3,-(a7)

	; Perform the standard AES fsel_input call.
	bsr	linea_showmouse
	bsr	aes_fsel_input
	bsr	linea_hidemouse

	; Check if an error (d0 = 0) occurred.
	tst.l	d0
	beq.s	.err
	; (a0) contains the absolute path of the selected
	; directory, fsel_file contains the selected filename.

	; Concatenate the selected pathname with the selected
	; filename to form the absolute path of the selected file.
	lea	fsel_file(pc),a1
	lea	fsel_fullname(pc),a2
	movea.l	a2,a3
	move.w	#255,d0
.cp_d	move.b	(a0)+,(a2)+
	dbeq	d0,.cp_d
.fname	cmpa.l	a3,a2
	bls.s	.err
	cmpi.b	#'\',-(a2)
	bne.s	.fname
	move.w	#15,d0
	addq.l	#1,a2
.cp_f	move.b	(a1)+,(a2)+
	dbeq	d0,.cp_f
	clr.b	(a2)

	moveq.l	#0,d0
	movea.l	a3,a0

.ret	movem.l	(a7)+,d1/a1-a3
	rts

.err	moveq.l	#-1,d0
	suba.l	a0,a0
	bra.s	.ret

	;
	; buf_alloc()
	;
	; Allocate a buffer to load a regular file.
	;
	; First try to re-use the previously allocated buffer
	; if it is large enough. Otherwise free that buffer
	; and allocate a new one of the correct size.
	; The newly allocated buffer is saved for future use.
	;
	; In:
	;   d0: requested buffer size
	;
	; Out:
	;   d0: pointer to the allocated buffer, or 0 if there
	;       is not enough memory
	;
buf_alloc:
	movem.l	a0-a1,-(a7)

	lea	alloc_addr(pc),a1
	tst.l	(a1)
	beq.s	.alloc
	cmp.l	(alloc_size-alloc_addr)(a1),d0
	bls.s	.ret
.free	movea.l	(a1),a0
	bsr	mfree
.alloc	move.l	d0,(alloc_size-alloc_addr)(a1)
	bsr	malloc
	move.l	d0,(a1)

.ret	move.l	(a1),d0	
	movem.l	(a7)+,a0-a1
	rts

	;
	; buf_free()
	;
	; Free the buffer previously allocated and saved by
	; buf_alloc().
	; If no buffer was allocated, this function does nothing.
	;
buf_free:
	movem.l	a0-a1,-(a7)

	lea	alloc_addr(pc),a1
	tst.l	(a1)
	beq.s	.ret
	movea.l	(a1),a0
	bsr	mfree
	clr.l	(a1)

.ret	movem.l	(a7)+,a0-a1
	rts

	;
	; file_load()
	;
	; Open a file-selector dialog box and load the selected
	; file in memory.
	;
	; In:
	;   d0: if !0, first clear the default filename of the 
	;       file-selector (fsel_file)
	;   a0: message to be printed at the top of the screen
	;       when the file-selector dialog box appears
	;   a1: null-terminated string containing the default
	;       access path of the file-selector with appended
	;       search mask
	;
	; Out:
	;   file_addr: Address where the selected file was loaded,
	;              or 0 if no file was loaded or if an error
	;              occurred
	;   file_size: size of the file, or 0 if no file was loaded
	;
file_load:
	movem.l	d0-d3/a0-a3,-(a7)

	; First print the requested message at the top of the
	; screen. It explains why the file-selector is displayed.
	bsr	print

	; Copy the default access path in a buffer that is passed
	; to the file_select() function. This buffer is large enough
	; (256 bytes) to contain the absolute path of the selected
	; directory returned by the AES fsel_input call.
	lea	fsel_path_load(pc),a0
	movea.l	a0,a2
	move.w	#255,d1
.clear	clr.b	(a2)+
	dbf	d1,.clear
	movea.l	a0,a2
	moveq.l	#15,d1
.cp	move.b	(a1)+,(a2)+
	dbeq	d1,.cp

	; Clear file_addr and file_size so that they are null
	; in case of error.
	lea	file_addr(pc),a2
	clr.l	(a2)
	clr.l	(file_size-file_addr)(a2)

	; Display the file-selector.
	bsr	file_select
	bsr	cls
	tst.l	d0
	bne.s	.ret

	; (a0) contains the absolute path of the selected file.
	; Check if that file can be accessed.
	move.w	#%100111,d0
	bsr	fsfirst
	tst.l	d0
	beq.s	.dta
	; File cannot be accessed, take the error path.
	lea	txt_read_err(pc),a0
	bra.s	file_ret

	; Get the size of the file from the DTA.
	; It is used to allocated the buffer in which the
	; file is loaded.
.dta	bsr	fgetdta
	movea.l	d0,a1
	move.l	26(a1),d1

	; If the static buffer that is used to save ripped
	; cracktros is large enough, used that buffer.
	; Otherwise allocate a new buffer using malloc().
.buf	cmpi.l	#INTRO_BUF_SIZE,d1
	bhi.s	.alloc
	move.l	intro_buf_rel(pc),d2
	bra.s	.open

.alloc	move.l	d1,d0
	bsr	buf_alloc
	move.l	d0,d2
	bne.s	.open
	; Buffer allocation failure, take the error path.
	lea	txt_mem_err(pc),a0
	bra.s	file_ret

	; Print "please wait..." and open the file.
.open	movea.l	a0,a1

	lea	txt_file_load(pc),a0
	bsr	print

	movea.l	a1,a0
	bsr	fopen
	tst.l	d0
	bpl.s	.read
	; File cannot be opened, take the error path.
	lea	txt_read_err(pc),a0
	bra.s	file_ret

	; Load the file in the static or allocated buffer.
.read	movea.l	d2,a0
	move.l	d0,d3	
	bsr	fread
	exg	d0,d3

	; Close the file.
.close	bsr	fclose
	sub.l	d1,d3
	beq.s	.ok
	; File loading failed, take the error path.
	lea	txt_read_err(pc),a0
	bra.s	file_ret

	; File loading succeeded: update file_addr and file_size.
.ok	move.l	d2,(a2)
	move.l	d1,(file_size-file_addr)(a2)

.ret	bsr	cls

	movem.l	(a7)+,d0-d3/a0-a3
	rts

	;
	; file_ret()
	;
	; Execution path taken by file_load() and file_save()
	; when an error occurs while loading or saving a file.
	;
	; It clears the screen, print a message of error and
	; waits for a keystroke to return to the main menu.
	;
	; In:
	;   a0: error message
	;
file_ret:
	bsr	cls
	bsr	print

	lea	txt_return_main(pc),a0
	bsr	print
	bsr	readchar

	bsr	cls

	movem.l	(a7)+,d0-d3/a0-a3
	rts

	;
	; file_save()
	;
	; Open a file-selector dialog box and save the buffer
	; containing the ripped cracktro to the selected file.
	;
	; In:
	;   d0: if !0, first clear the default filename of the 
	;       file-selector (fsel_file)
	;   a0: message to be printed at the top of the screen
	;       when the file-selector dialog box appears
	;   path_drv_dest: null-terminated string containing the
	;                  default access path of the file-selector
	;                  with appended search mask; this path is
	;                  ignored once fsel_path_save has been
	;                  updated by the file-selector with the
	;                  latest selected path
	;   fsel_path_save: latest path selected for file saving;
	;                   this path is automatically used as the
	;                   default access path for the subsequent
	;                   saving of a file
	;   file_size: size of the file to be saved
	;   file_addr: content of the file to be saved
	;
file_save:
	movem.l	d0-d3/a0-a3,-(a7)

	; First print the requested message at the top of the
	; screen. It explains why the file-selector is displayed.
	bsr	print

	; fsel_path_save is a 256-bytes buffer which contains
	; the latest selected path for file saving.
	; It is first initialized by copying the contents of
	; path_drv_dest to it, then it is passed to the AES
	; fsel_input() which will store the selected path.
	; This path will then be automatically used as the
	; default path for the subsequent saving of a file.
	lea	fsel_path_save(pc),a3
	tst.b	(a3)
	bne.s	.swap_a
	; Copy path_drv_dest only if fsel_path_save is empty.
	movea.l	a3,a2
	move.w	#255,d1
.clear	clr.b	(a2)+
	dbf	d1,.clear
	lea	path_drv_dest(pc),a1
	movea.l	a3,a2
	moveq.l	#15,d1
.cp	move.b	(a1)+,(a2)+
	dbeq	d1,.cp

	; In which drive is the destination disk expected?
.swap_a	cmpi.b	#'A',(a3)
	bne.s	.fsel

	move.l	d0,-(a7)

	; If the destination disk is expected in drive A,
	; ask to insert it and wait for a keystroke.
	move.l	a0,-(a7)
	lea	txt_save_change_disk(pc),a0
	bsr	print
	bsr	readchar        ; Corrupt d0
	movea.l	(a7)+,a0
	bsr	cls
	bsr	print

	; First updates the BPB of drive A.
	moveq.l	#0,d0
	bsr	getbpb

	; Then, makes the GEMDOS assume that the floppy disk in
	; drive A has changed, so that subsequent GEMDOS file
	; functions work correctly. Otherwise, the GEMDOS may use
	; the cached information about the previous disk (geometry,
	; FAT, directories) to access the contents of the new disk,
	; which may result in incorrect data being read.
	; Forcing the GEMDOS to assume that the disk in drive A
	; has changed and that the cached information should be
	; updated, is done by hooking the mediach and getbpb
	; vectors ($47e and $472).
	; See mediach_hook() and getbpb_hook() for details.
	lea	mediach_forced(pc),a0
	move.w	#0,(a0)

	move.l	(a7)+,d0

	; Tell the user to choose an unused destination filename
	; and then display the file-selector.
.fsel	lea	txt_save_select(pc),a0
	bsr	print
	movea.l	a3,a0
	bsr	file_select
	bsr	cls
	tst.l	d0
	beq.s	.fs1st
	; File saving cancelled, take the error path.
	lea	txt_file_cancel(pc),a0
	bra	file_ret

	; (a0) contains the absolute path of the selected file.
	; Check if that file already exists.
.fs1st	move.w	#%100111,d0
	bsr	fsfirst
	; Continue only if the file does not exist.
	cmpi.l	#-33,d0         ; EFILNF
	beq.s	.create
	; File already exists, take the error path.
	lea	txt_fexist_err(pc),a0
	bra	file_ret

	; Print "please wait..." and create the file.
.create	movea.l	a0,a1

	bsr	cls
	lea	txt_file_save(pc),a0
	bsr	print

	movea.l	a1,a0
	bsr	fcreate
	tst.l	d0
	bpl.s	.write
	; File creation failed, take the error path.
	lea	txt_write_err(pc),a0
	bra	file_ret

	; Write the contents of the file: file_size bytes
	; starting from file_addr.
.write	movea.l	file_addr(pc),a0
	move.l	file_size(pc),d1
	move.l	d0,d2
	bsr	fwrite
	exg	d0,d2

	; Close the file.
.close	bsr	fclose
	; File saving succeeded, print a confirmation message
	; (take the error path although there is no error,
	; because it just prints our message, which is what
	; we need).
	lea	txt_file_save_success(pc),a0
	sub.l	d1,d2
	beq	file_ret
	; File saving failed, take the error path.
	lea	txt_write_err(pc),a0
	bra	file_ret

	;
	; bootsector_trampoline()
	;
	; Trampoline code executed by the exec_boot() routine
	; to rip a boot-cracktro.
	; This simple code just copies the content of the
	; bootsector (which was loaded in bootsector_buf) to
	; the _dskbufp buffer ($4c6) where it is executed.
	;
	; See exec_boot() and rip() for details.
	;
bootsector_trampoline:
	movea.l	_dskbufp(pc),a0
	movem.l	d0/a0-a1,-(a7)
	lea	bootsector_buf(pc),a1
	move.w	#512/4-1,d0
.cp	move.l	(a1)+,(a0)+
	dbf	d0,.cp
	movem.l	(a7)+,d0/a0-a1
	; Execute the bootsector.
	jmp	(a0)

	;
	; rip()
	;
	; Rip a boot-cracktro.
	;
	; This routine is called by the main menu when the
	; option "Rip a boot-cracktro" is selected.
	;
	; It does the following:
	; - Prints a message asking to insert the disk which
	;   contains the boot-cracktro to be ripped.
	; - Reads the bootsector and checks if it is executable.
	; - If it is executable, calls the exec_boot() routine
	;   to create a sandbox where the bootsector is executed
	;   until the boot-cracktro is ripped.
	; - If it is not executable or if it loads no cracktro,
	;   checks if the disk contains regular files.
	;   If this is the case, opens a file-selector dialog box
	;   to allow to copy one of the files present on the disk.
	; - Saves the ripped cracktro or the regular file that was
	;   manually selected and loaded.
	; - Prints a confirmation or an error message and waits
	;   for a keystroke to return to the main menu.
	;
rip:
	movem.l	d0-d2/a0-a2,-(a7)

	; Print the message asking to insert the disk and wait
	; for a keystroke.
	lea	txt_rip_start(pc),a0
	bsr	print
	bsr	readchar

	bsr	cls

	; Read the bootsector and check if it is executable.
	bsr	boot_read
	; If the bootsector is executable, run it in the sandbox.
	tst.l	d0
	beq.s	.exec
	; If it is not executable, check if the disk contains
	; regular files.
	cmpi.w	#ENOBOOT,d0
	beq	.rip_file
	; If the bootsector cannot be read, print an error message.
	lea	txt_boot_err(pc),a0
	bra.s	.err_ret
.exec
	; The bootsector is executable, create a sandbox and
	; run the bootsector until a cracktro is ripped.
	lea	exec_boot(pc),a0
	lea	bootsector_trampoline(pc),a1
	bsr	supexec

	bsr	cls

	; Check if an error occurred during the "ripping" work.
	tst.l	d0
	beq.s	.chk_load
	; An error occurred, take the error path.
	lea	txt_exec_err(pc),a0
	bra.s	.err_ret
.chk_load
	; Check if a cracktro was loaded by the bootsector.
	lea	intro_load_addr(pc),a0
	tst.l	(a0)
	; If no cracktro was loaded, check if the disk contains
	; regular files.
	beq	.rip_file

	; A cracktro was loaded by the bootsector and no error
	; occurred, prepare the cracktro for saving.
	bra.s	.rip_boot

	; Error path: print an error message and wait for
	; a keystroke to return to the main menu.
.err_ret
	bsr	print
	lea	txt_return_main(pc),a0
	bsr	print
	bsr	readchar

	bsr	cls

.ret	movem.l	(a7)+,d0-d2/a0-a2
	rts

	;
	; The rip() routine jumps here if a cracktro was loaded by
	; the bootsector and ripped by exec_boot().
	; The following routine prepares the cracktro for saving,
	; opens a file-selector dialog box and saves the cracktro
	; to the selected file.
	;
	; The ripped cracktro is wrapped in a special code (called
	; preamble) whose purpose is to make the cracktro executable
	; from the GEM. The resulting program is saved as a regular
	; PRG file.
	;
.rip_boot:
	lea	intro_header_dest(pc),a0   ; Preamble
	lea	intro_buf(pc),a1           ; Ripped cracktro

	; Is the ripped cracktro a regular executable (with a
	; PRG header) or a raw binary?
	move.l	intro_prg_size(pc),d1
	bne.s	.exe

	; Raw binary case:
	; - Determine the size of the ripped binary (which is
	;   a multiple of 512-bytes).
	; - Patch the preamble to save the size of the ripped
	;   binary and to indicate that it is a simple binary
	;   (with no relocation/fixup table).
.bin	move.l	intro_buf_next(pc),d0
	sub.l	a1,d0
	move.l	d0,(intro_size-intro_header)(a0)
	clr.w	(intro_text_offset+2-intro_header)(a0)
	bra.s	.addr

	; PRG case:
	; - Determine the actual size of the cracktro code/data
	;   (discarding the fixup table).
	; - Round this size up to a 8-byte boundary (the copy
	;   routine of the preamble copies the cracktro in 8-byte
	;   chunks).
	; - Patch the preamble to save the rounded size and to
	;   indicate that the cracktro is a PRG (that has a
	;   relocation/fixup table).
.exe	moveq.l	#$1c+7,d0
	add.l	2(a1),d0                   ; Text
	add.l	6(a1),d0                   ; Data
	andi.l	#$fffffff8,d0
	move.l	d0,(intro_size-intro_header)(a0)
	move.l	d1,d0
	move.w	#$1c,(intro_text_offset+2-intro_header)(a0)

	; Patch the preamble to save the address where the cracktro
	; must be installed to be executed.
	; It is the address where the cracktro was loaded by the
	; bootsector.
.addr	move.l	intro_load_addr(pc),d1
	move.l	d1,(intro_start_addr-intro_header)(a0)

	; Prepare the final PRG containing the preamble and the
	; cracktro:
	; - Compute the size of the text section, it contains
	;   the preamble code followed by the cracktro.
	; - Round this size up to the nearest even.
	; - Patch the final PRG header with the resulting text
	;   section size.
	; - Add a NULL longword (0L) at the end of the PRG to
	;   indicate there is no fixup table (the preamble code
	;   is position-independent).
	;
	addi.l	#intro_preamble_end-intro_preamble,d0
	lea	(intro_preamble-intro_header)(a0,d0.l),a1
	addq.l	#1,d0
	bclr	#0,d0
	move.l	d0,2(a0)
	moveq.l	#5-1,d1
.clear	clr.b	(a1)+
	dbf	d1,.clear
	addi.l	#(intro_preamble-intro_header+4),d0

	; The final PRG is ready.
	; Save the PRG start address and size in file_addr and
	; file_size respectively, so that the file_save() routine
	; can save the PRG to the file selected by the user.
	lea	file_addr(pc),a1
	move.l	a0,(a1)
	move.l	d0,(file_size-file_addr)(a1)

	; Call file_save() to open a file-selector dialog box
	; and save the final PRG file.
	lea	txt_boot_save_select(pc),a0
	moveq.l	#1,d0
	bsr	file_save
	bra.s	.ret

	;
	; The rip() routine jumps here if the bootsector was not
	; executable or was executable but did not load a cracktro
	; (for instance, the bootsector contains an anti-virus).
	; The following routine checks if the disk contains regular
	; files. If it does, a first file-selector dialog box is
	; opened to allow to load one of the files present on the
	; disk, then a second file-selector dialog box is opened
	; to allow to save that file to a different location.
	;
.rip_file:
	; First check if the disk contains regular files.
	; This is done by reading the sectors directly and checking
	; the FAT12 root directory, without GEMDOS assistance.
	bsr	check_files
	tst.l	d0
	beq.s	.files
	; If there are no files on the disk, take the error path.
	lea	txt_nofile(pc),a0
	bra	.err_ret
.files
	; Files have been found on the disk.
	; First updates the BPB of drive A.
	moveq.l	#0,d0
	bsr	getbpb

	; Then, makes the GEMDOS assume that the floppy disk in
	; drive A has changed, so that subsequent calls to fsfirst
	; work correctly. Otherwise, the GEMDOS may use the cached
	; information about the previous disk (geometry, FAT,
	; directories) to access the contents of the new disk,
	; which may result in incorrect data being read.
	; Forcing the GEMDOS to assume that the disk in drive A
	; has changed and that the cached information should be
	; updated, is done by hooking the mediach and getbpb
	; vectors ($47e and $472).
	; See mediach_hook() and getbpb_hook() for details.
	lea	mediach_forced(pc),a0
	move.w	#0,(a0)

	; There was no boot cracktro on the disk, but a cracktro
	; may be present on the disk as a regular executable.
	; The cracktro can be a PRG or a TOS file. It can be
	; located at the root or in the AUTO folder.
	; Let's check the different possibilities and build a
	; bitmask describing them:
	; AUTO/PRG  ROOT/PRG  ROOT/TOS     FS PATH
	;        0         0         0    ROOT/ANY
	;        0         0         1    ROOT/TOS
	;        0         1         0    ROOT/PRG
	;        0         1         1    ROOT/ANY
	;        1         0         0    AUTO/PRG
	;        1         0         1    ROOT/ANY
	;        1         1         0    ROOT/PRG
	;        1         1         1    ROOT/ANY
	; The resulting bitmask will be used to determine
	; the default access path of the file-selector,
	; to make it easier for the user (FS PATH above).

	; First check if there is a PRG file in the AUTO folder.
	move.w	#%100111,d1
	moveq.l	#0,d2
	lea	path_drv_a_auto(pc),a0
	move.w	d1,d0
	bsr	fsfirst
	tst.l	d0
	bne.s	.prg
	; File found, update the bitmask.
	bset	#2,d2

	; Then check if there is a PRG file at the root.
.prg	lea	path_drv_a_prg(pc),a0
	move.w	d1,d0
	bsr	fsfirst
	tst.l	d0
	bne.s	.tos
	; File found, update the bitmask.
	bset	#1,d2

	; Then check if there is a TOS file at the root.
.tos	lea	path_drv_a_tos(pc),a0
	move.w	d1,d0
	bsr	fsfirst
	tst.l	d0
	bne.s	.select
	; File found, update the bitmask.
	bset	#0,d2

	; Use the resulting bitmask as an index in the
	; path_drv_a_table table, to get the default access
	; path of the file-selector.
.select	lsl.l	#2,d2
	lea	path_drv_a_table(pc),a1
	adda.l	0(a1,d2.w),a1
	; Open a file-selector dialog box and load the cracktro
	; file selected manually.
	; Use the default access path computed above, but reset
	; the default filename.
	lea	txt_file_load_select(pc),a0
	moveq.l	#1,d0
	bsr	file_load
	; No file loaded? Return now.
	move.l	file_addr(pc),d0
	beq	.ret

	; File loaded successfully and ready to be saved.
	; Open a second file-selector dialog box for saving.
	; The default filename is the name of the file that
	; has just been loaded. The default access path is
	; the one used during the previous saving.
	lea	txt_file_save_select(pc),a0
	moveq.l	#0,d0
	bsr	file_save
	bra	.ret

	;
	; FAT12 Bios Parameter Block offsets.
	; These are the offsets within the bootsector BPB.
	;
BPB_OEM       =	$02
BPB_SERIAL    =	$08
BPB_BPS       =	$0b
BPB_SPC       =	$0d
BPB_RES       =	$0e
BPB_NFATS     =	$10
BPB_NDIRS     =	$11
BPB_NSECS     =	$13
BPB_MEDIA     =	$15
BPB_SPF       =	$16
BPB_SPT       =	$18
BPB_NHEADS    =	$1a
BPB_NHID      =	$1c
BPB_SIZE      =	$1e

	; Internal error codes.
ENOBOOT       =	-20             ; Bootsector not executable
ENOFAT        =	-21             ; No filesystem present on the disk

	; Invalid device number.
DEV_INVALID   =	$ffff

	;
	; This program allows to process several floppy disks,
	; one after the other. Each time the user inserts a new
	; floppy disk, it is analyzed to determine whether it
	; contains a boot cracktro or only regular files. This
	; analysis is performed by reading the sectors of the
	; floppy disk directly without GEMDOS assistance. If
	; the floppy disk contains regular files, the user is
	; asked to select a file and the GEMDOS is then invoked
	; to copy that file. But it often happens that the GEMDOS
	; does not detect the disk change and uses the cached
	; information about the previous disk (geometry, FAT,
	; directory) to access the contents of the new disk.
	; When this happens, the GEMDOS may read wrong data.
	;
	; In order to overcome this problem, it is possible to
	; force the GEMDOS to assume that the disk has indeed
	; been changed and that the cached information should
	; be updated.
	;
	; Here is how the GEMDOS handles media changes: each time
	; the floppy disk should be accessed, the GEMDOS inquires
	; about a media change by calling, via the Bios, the
	; mediach routine registered in the mediach vector ($47e).
	; If the mediach routine indicates that the floppy disk has
	; changed, then the GEMDOS resets the cached information
	; about the current floppy disk. This starts by reading,
	; via the Bios, the BPB of the new floppy disk (containing
	; basic filesystem information). The BPB is read by the
	; Bios by calling the getbpb routine registered in the
	; getbpb vector ($472).
	;
	; Here's how to take advantage of this execution sequence
	; to force the detection of media changes and the reset
	; of cached disk information:
	; - The mediach and getbpb vectors are hooked to install
	;   custom handlers.
	; - By construction, this program always knows when a new
	;   floppy disk has been inserted.
	; - The first GEMDOS service that is used after inserting
	;   a new disk is fsfirst, to search for an executable on
	;   the disk.
	; - Just before calling fsfirst, the mediach_forced
	;   variable is set so that our custom mediach routine,
	;   when called by the Bios, indicates that the disk has
	;   changed.
	; - This will cause the BPB to be read and thus a call
	;   from the Bios to our custom getbpb routine.
	; - This will reset the variable mediach_forced so that
	;   the mediach routine will return to standard behavior.
	;

	;
	; getbpb_hook()
	;
	; Custom getbpb routine, registered in the getbpb vector
	; and called by the Bios to read the BPB.
	;
	; This routine resets the mediach_forced variable so that
	; the mediach routine returns to standard behavior, and
	; calls the original getbpb routine to read the BPB.
	;
	; Scratch: d0/a0
	;
getbpb_hook:
	lea	mediach_forced(pc),a0
	move.w	4(a7),d0
	cmp.w	(a0),d0
	bne.s	getbpb_orig
	move.w	#DEV_INVALID,(a0)
getbpb_orig:
	jmp	$0.l        ; Original getbpb routine

	;
	; mediach_hook()
	;
	; Custom mediach routine, registered in the mediach vector
	; and called by the Bios to ask if the media has changed.
	;
	; If the mediach_forced variable is equal to the logical
	; device passed as parameter, this routine returns a value
	; indicating that the media has changed.
	; Otherwise, it just calls the original mediach routine.
	;
	; Scratch: d0/a0
	;
mediach_hook:
	lea	mediach_forced(pc),a0
	move.w	4(a7),d0
	cmp.w	(a0),d0
	bne.s	mediach_orig
	moveq.l	#2,d0       ; Media definitely has changed
	rts
mediach_orig:
	jmp	$0.l        ; Original mediach routine

	;
	; check_files()
	;
	; This routine checks whether the floppy disk (in drive A)
	; has a FAT12 filesystem with regular files.
	;
	; After a new floppy disk has been inserted into drive A,
	; this program checks whether it contains a boot cracktro.
	; If no boot cracktro is found, the following routine is
	; then called to check whether the floppy disk actually
	; contains regular files.
	;
	; Because the floppy disk may have no FAT filesystem but
	; only contain raw data, the GEMDOS cannot be used to
	; check whether files exist. Indeed, accessing a floppy
	; disk without FAT using the GEMDOS could cause a system
	; crash.
	;
	; The following routine scans the first sectors of the
	; floppy disk to determine if it has a FAT12 filesystem.
	; In particular, the routine scans the sectors of the
	; root directory for file names.
	;
	; Out:
	;   d0: 0 if the disk contains regular files, the ENOFAT
	;       error code otherwise
	;
check_files:
	movem.l	d1-d6/a0-a1,-(a7)

	; The bootsector has already been loaded into
	; bootsector_buf.
	lea	bootsector_buf(pc),a0

	moveq.l	#0,d0
	moveq.l	#0,d1
	moveq.l	#0,d2
	moveq.l	#0,d3

	;
	; First, let's perform sanity checks on the BPB values.
	; The BIOS Parameter Block (BPB) is part of the FAT12
	; specification.
	; BPB values are stored in little-endian in the
	; bootsector.
	;

	; Check that sectors are 512 bytes.	
	tst.b	BPB_BPS+0(a0)
	bne	.err
	cmpi.b	#$02,BPB_BPS+1(a0)
	bne	.err
	move.b	BPB_SPC(a0),d0
	beq	.err
	; d3 = number of sectors per cluster.
	move.b	d0,d3
	; Check that it is a power of two.
	subq.b	#1,d0
	and.b	d3,d0
	bne	.err
	tst.b	BPB_SPT+1(a0)
	bne	.err
	; d0 = number of sectors per track.
	move.b	BPB_SPT+0(a0),d0
	; Check that it is 9, 10 or 11.
	cmpi.b	#9,d0
	blo	.err
	cmpi.b	#11,d0
	bhi	.err
	tst.b	BPB_NHEADS+1(a0)
	bne	.err
	; d1 = number of heads (sides).
	move.b	BPB_NHEADS+0(a0),d1
	; Check that it is 1 or 2.
	beq	.err
	cmpi.b	#2,d1
	bhi	.err
	move.b	BPB_NSECS+1(a0),d2
	lsl.w	#8,d2
	move.b	BPB_NSECS+0(a0),d2
	; d4 = total number of physical sectors.
	move.l	d2,d4
	; Deduce the total number of tracks.
	divu.w	d0,d2           ; / sectors per track
	ext.l	d2
	divu.w	d1,d2           ; / heads
	; Check that it is lower than 86.
	cmpi.w	#86,d2
	bhs	.err

	; d0 = number of File Allocation Tables (FAT) - usually 2.
	move.b	BPB_NFATS(a0),d0
	bne.s	.spf
	moveq.b	#2,d0
	; d1 = number of sectors per FAT.
.spf	move.b	BPB_SPF(a0),d1
	; d0 = total number of sectors for all FATs.
	mulu	d1,d0
	; d1 = number of reserved sectors - usually 1 (bootsector).
	move.b	BPB_RES(a0),d1
	bne.s	.dirsec
	moveq.b	#1,d1
	; The first sector of the root directory follows
	; the reserved and FATs sectors.
	; d0 = first sector of the root directory.
.dirsec	add.l	d1,d0
	; Check that it does not exceed the total number
	; of sectors.
	cmp.l	d4,d0
	bhs	.err
	move.l	d0,d5
	; d1 = number of 32-bytes entries in the root directory.
	move.b	BPB_NDIRS(a0),d1
	; d1 = number of sectors containing the root directory.
	lsr.b	#4,d1
	; d5 = first sector containing files data.
	add.l	d1,d5
	; Check that it does not exceed the total number
	; of sectors.
	cmp.l	d4,d5
	bhs	.err

	;
	; The BPB has valid values.
	; Now let's scan the first sector of the root directory
	; for file names.
	;

	; Read the first sector of the root directory.
	movea.l	a0,a1
	lea	sector_buf(pc),a0
	moveq.l	#1,d1
	bsr	sector_read
	tst.l	d0
	bne	.ret

	; 16 entries of 32 bytes each.
	moveq.l	#15,d0
	moveq.l	#0,d6

.newent	; End of directory?
	tst.b	(a0)
	beq	.end

	; Free entry?
	cmpi.b	#$e5,(a0)
	beq.s	.nxtent

	; Volume label?
.attr	btst.b	#3,11(a0)
	bne.s	.nxtent

	; Check the filename.
	moveq.l	#10,d2
.name	move.b	0(a0,d2.w),d1
	; Character DEL is not allowed.
	cmpi.b	#$7f,d1
	beq.s	.nxtent
	; Control characters are not allowed either.
	cmpi.b	#$20,d1
	blo.s	.nxtent
.nxtchr	dbf	d2,.name

	; Check that the unused fields on Atari ST are zero.
.unused	tst.w	12(a0)          ; Reserved
	bne.s	.nxtent
	tst.w	14(a0)          ; Creation time
	bne.s	.nxtent
	tst.w	16(a0)          ; Creation date
	bne.s	.nxtent
	tst.w	18(a0)          ; Last access date
	bne.s	.nxtent
	tst.w	20(a0)          ; Ignored
	bne.s	.nxtent

	; Check the first logical cluster.
.clust	moveq.l	#0,d1
	; d1 = first logical cluster.
	move.b	27(a0),d1
	lsl.w	#8,d1
	move.b	26(a0),d1
	; First logical cluster value is 2.
	subq.w	#2,d1
	mulu.w	d3,d1           ; * sectors per cluster
	; d1 = starting sector of the file.
	add.l	d5,d1
	; Check that it does not exceed the total number
	; of sectors.
	cmp.l	d4,d1
	bhi.s	.nxtent

	; Check the file size.
.size	moveq.l	#0,d1
	; d1 = size of the file in bytes.
	move.b	31(a0),d1
	lsl.l	#8,d1
	move.b	30(a0),d1
	lsl.l	#8,d1
	move.b	29(a0),d1
	lsl.l	#8,d1
	move.b	28(a0),d1
	lsr.l	#8,d1
	lsr.l	#1,d1
	; d1 = size of the file in 512 bytes sectors.
	addq.l	#1,d1
	add.l	d5,d1
	; Check that it does not exceed the total number
	; of sectors.
	cmp.l	d4,d1
	bhi.s	.nxtent

	; Increment the number of valid files found.
	addq.w	#1,d6

	; Next entry.
.nxtent	lea	32(a0),a0
	dbf	d0,.newent

	; Any valid files found?
.end	tst.w	d6
	beq.s	.err

	; The disk contains files.
	moveq.l	#0,d0
.ret	movem.l	(a7)+,d1-d6/a0-a1
	rts

	; The disk does not contain a valid FAT12 filesystem.
.err	moveq.l	#ENOFAT,d0
	bra.s	.ret

	;
	; boot_read()
	;
	; Read the bootsector of the floppy disk inserted in
	; drive A and check if it is executable.
	;
	; Out:
	;   d0: 0 if the bootsector has been read correctly and
	;      is executable, an error code otherwise
	;   bootsector_buf: the bootsector content
	;
boot_read:
	movem.l	d1-d2/a0-a2,-(a7)

	move.w	#1,-(a7)        ; 1 sector
	move.w	#0,-(a7)        ; Side 0
	move.w	#0,-(a7)        ; Track 0
	move.w	#1,-(a7)        ; Sector 1
	move.w	#0,-(a7)        ; Drive A:
	clr.l	-(a7)
	pea	bootsector_buf(pc)
	move.w	#8,-(a7)        ; Floprd
	trap	#14
	lea	20(a7),a7
	tst.l	d0              ; XBios error code
	bne.s	.ret

	; The bootsector is executable if the checksum
	; of the whole bootsector is $1234.
	lea	bootsector_buf(pc),a0
	move.w	#(512/2)-1,d0
	moveq.l	#0,d1
.csum	add.w	(a0)+,d1
	dbf	d0,.csum
	moveq.l	#0,d0           ; No error
	cmpi.w	#$1234,d1
	beq.s	.ret
	moveq.l	#ENOBOOT,d0     ; Not executable

.ret	movem.l	(a7)+,d1-d2/a0-a2
	rts

	;
	; sector_read()
	;
	; Read logical sectors from the floppy disk inserted
	; in drive A.
	; This routine mimics the Rwabs call of the Bios.
	; It uses the Floprd call of the XBios to read individual
	; sectors.
	;
	; The logical sectors are numbered from 0 (bootsector)
	; to SEC_PER_TRACKS*NR_TRACKS*NR_HEADS-1 (last sector).
	;
	; In:
	;   d0.w: logical starting sector
	;   d1.w: number of sectors to be read
	;   a0: address of the receiving buffer
	;   a1: FAT12 Bios Parameter Block (BPB)
	;
	; Out:
	;   d0: 0 if all sectors have been read correctly,
	;       an XBios error code otherwise
	;
sector_read:
	movem.l	d1-d6/a0-a4,-(a7)

	moveq.l	#0,d4
	move.w	d0,d4             ; d4 = logical sector nr
	moveq.l	#0,d5
	move.w	d1,d5             ; d5 = total sector count
	movea.l	a0,a3             ; a3 = destination buffer
	movea.l	a1,a4             ; a4 = FAT12 BPB

.lp	move.l	d4,d3             ; d3 = logical sector nr
	moveq.l	#0,d1
	move.b	BPB_SPT(a4),d1    ; d1 = sectors per track
	move.l	d1,d0             ; d0 = sectors per track
	divu.w	d1,d3
	moveq.l	#0,d2
	move.w	d3,d2             ; d2 = logical track nr
	swap	d3
	addq.w	#1,d3             ; d3.w = sector nr
	move.b	BPB_NHEADS(a4),d1 ; d1 = number or heads
	divu.w	d1,d2             ; d2.w = track nr
	move.l	d2,d1
	swap	d1                ; d1.w = side nr

	sub.w	d3,d0
	addq.w	#1,d0             ; d0 = sector count
	cmp.w	d5,d0
	bls.s	.next
	move.w	d5,d0             ; Should be <= SPT

.next	sub.w	d0,d5             ; Update total sec count
	add.w	d0,d4             ; Update logical sec nr
	move.l	d0,d6
	lsl.l	#8,d6
	lsl.l	#1,d6             ; d6 = transfer size
	movea.l	a3,a0             ; a0 = transfer address
	adda.l	d6,a3             ; a3 = next transfer addr

	move.w	d0,-(a7)          ; Sector count
	move.w	d1,-(a7)          ; Side nr
	move.w	d2,-(a7)          ; Track nr
	move.w	d3,-(a7)          ; Sector nr
	move.w	#0,-(a7)          ; Drive A:
	clr.l	-(a7)
	move.l	a0,-(a7)          ; Transfer address
	move.w	#8,-(a7)          ; Floprd
	trap	#14
	lea	20(a7),a7
	tst.l	d0                ; Error?
	bne.s	.ret

	tst.w	d5                ; More sectors?
	bne.s	.lp

.ret	movem.l	(a7)+,d1-d6/a0-a4
	rts

	;
	; boot2bios_bpb()
	;
	; Convert a FAT12-style BPB (stored in the bootsector)
	; into a Bios-style BPB (returned by the Getbpb() call).
	;
	; In:
	;   a0: input buffer containing the FAT12 BPB
	;   a1: output buffer that will contain the Bios BPB
	;
	; Out:
	;   d0: address of the Bios BPB (same as a1)
	;
boot2bios_bpb:
	movem.l	d1-d3/a0-a1,-(a7)
	move.l	a1,-(a7)

	move.w	#$200,(a1)+    ; Bytes per sector
	moveq.l	#0,d0
	move.b	BPB_SPC(a0),d0
	move.w	d0,(a1)+       ; Sectors per cluster
	moveq.l	#9,d1
	move.l	d0,d2
	lsl.l	d1,d2
	move.w	d2,(a1)+       ; Bytes per cluster
	move.b	BPB_NDIRS(a0),d1
	lsr.b	#4,d1
	move.w	d1,(a1)+       ; Root dir length in sectors
	move.b	BPB_SPF(a0),d1
	move.w	d1,(a1)+       ; Sectors per FAT
	moveq.l	#0,d2
	move.b	BPB_RES(a0),d2
	bne.s	.2ndfat
	moveq.b	#1,d2
.2ndfat	move.l	d1,d3
	add.w	d2,d3
	move.w	d3,(a1)+       ; Start of the 2nd FAT
	move.b	BPB_NFATS(a0),d3
	bne.s	.datsec
	moveq.b	#2,d3
.datsec	mulu.w	d1,d3
	add.w	d2,d3
	add.w	-6(a1),d3	
	move.w	d3,(a1)+       ; 1st free (data) sector
	move.b	BPB_NSECS+1(a0),d2
	lsl.w	#8,d2
	move.b	BPB_NSECS+0(a0),d2
	sub.w	d3,d2
	divu.w	d0,d2
	move.w	d2,(a1)+       ; Total number of clusters

	movem.l	(a7)+,d0-d3/a0-a1
	rts

	;
	; seek_track0()
	;
	; Issue a restore command to the WD1772 FDC controller,
	; in order to seek drive A to track 0.
	;
seek_track0:
	movem.l	d0/a0,-(a7)

	move.w	$43e.w,-(a7)    ; Save flock
	st	$43e.w          ; Take flock

	lea	$ffff8600.w,a0  ; DMA registers bank

	moveq.l	#2,d0           ; Select drive A and side 0
	bsr.s	fdc_select

	; Select FDC control register of read mode.
	move.w	#$80,6(a0)

	; Issue a restore (seek track 0) command:
	; Enable spin-up sequence (motor on), verify,
	; 3 ms stepping rate.
	moveq.l	#$7,d0
	bsr.s	write_fdc_reg

	bsr.s	wait_dma_irq    ; Wait for end of DMA

	move.w	(a7)+,$43e.w    ; Restore flock

	movem.l	(a7)+,d0/a0
	rts

	;
	; write_fdc_reg()
	;
	; Write a value to the selected FDC register while
	; taking timings constraints into account.
	;
	; Timings information is provided in the WD177x datasheet:
	; https://info-coach.fr/atari/documents/_datasheets/WD177x-Prog.txt
	; In particular, it is stated that after the CPU writes to
	; any register, it cannot read that register for 16us.
	; The following routine inserts a 25us delay before and
	; after writing to a freshly selected FDC register.
	; Note that Linux FDC driver does the same.
	;
	; In:
	;   d0: data to be written to the selected FDC register
	;   a0: $ffff8600
	;
write_fdc_reg:
	; Wait to cope with device timings.
	bsr.s	busy_delay
	; Write data to the selected FDC register.
	move.w	d0,4(a0)
	; Wait to cope with device timings.
	;
	; fall through.

	;
	; busy_delay()
	;
	; Insert a 25us busy-delay.
	;
busy_delay:
	movem.l	d0-d1,-(a7)

	moveq.l	#5,d0
	add.l	$4ba.w,d0
.wait	move.l	d0,d1
	sub.l	$4ba.w,d1
	bpl.s	.wait

	movem.l	(a7)+,d0-d1
	rts

	;
	; read_fdc_status()
	;
	; Return the FDC status.
	;
	; In:
	;   a0: $ffff8600
	;
	; Out:
	;   d0: FDC status
	;
read_fdc_status:
	; Select FDC control register of read mode.
	move.w	#$80,6(a0)
	bsr.s	busy_delay
	; Read FDC status.
	move.w	4(a0),d0
	rts

	;
	; wait_dma_irq()
	;
	; Wait for the end of the current DMA operation.
	;
	; If the DMA operation times out, a force interrupt
	; command is issued.
	;
	; In:
	;   a0: $ffff8600
	;
	; Out:
	;   d0: 0 if success, != 0 if error
	;
wait_dma_irq:
	; Timeout = $10000*25us > 1.6s.
	move.l	#$10000,d0

	; Check FDC interrupt bit in GPIO General Purpose register.
.poll	btst	#5,$fffffa01.w
	beq.s	.done
	bsr.s	busy_delay
	subq.l	#1,d0
	bne.s	.poll

	; Timeout: issue a force interrupt command.
	move.w	#$d0,d0
	bsr.s	write_fdc_reg

	; Wait 16*25us > 400us.
	moveq.l	#15,d0
.wait	bsr.s	busy_delay
	dbf	d0,.wait

	; Error: d0 != 0
	rts

	; Success: d0 = 0
.done	moveq.l	#0,d0
	rts

	;
	; fdc_select()
	;
	; FDC drive & side selection.
	;
	; In:
	;   d0: Bit0: 0 selects side 0, 1 selects side 1
	;       Bit1: 1 selects drive A, 0 deselects it
	;       Bit2: 1 selects drive B, 0 deselects it
	;   a0: $ffff8600
	;
fdc_select:
	move.l	d1,-(a7)
	; Save interrupts.
	move.w	sr,-(a7)
	; Disable interrupts.
	ori.w	#$700,sr
	; Select PSG register 14 (Port A).
	move.b	#14,$200(a0)
	; Read PSG register 14.
	move.b	$200(a0),d1
	; Clear drive A/B & side selection bits (0-2).
	andi.b	#$f8,d1
	; Bits of the floppy interface in PSG reg 14 are inverted:
	; Bit0: 1 selects side 0, 0 selects side 1
	; Bit1: 0 selects drive A, 1 deselects it
	; Bit2: 0 selects drive B, 1 deselects it
	or.b	d0,d1
	eori.b	#7,d1
	; Write PSG register 14.
	move.b	d1,$202(a0)
	; Restore interrupts.
	move.w	(a7)+,sr
	move.l	(a7)+,d1
	rts

	;
	; drv_a_selected()
	;
	; Interrogate FDC drive A selection.
	;
	; In:
	;   a0: $ffff8600
	;
	; Out:
	;   d0: !0 if drive A is selected, 0 otherwise
	;
drv_a_selected:
	; Save interrupts.
	move.w	sr,-(a7)
	; Disable interrupts.
	ori.w	#$700,sr
	; Select PSG register 14 (Port A).
	move.b	#14,$200(a0)
	; Read PSG register 14.
	moveq.l	#0,d0
	move.b	$200(a0),d0
	; Keep bit1 (drive A) and negate it.
	andi.b	#%010,d0
	eori.b	#%010,d0
	; Restore interrupts.
	move.w	(a7)+,sr
	rts

	;
	; fdc_deselect()
	;
	; Wait for drive A to shut down and deselect the drive.
	;
fdc_deselect:
	movem.l	d0/a0,-(a7)

	move.w	$43e.w,-(a7)    ; Save flock
	st	$43e.w          ; Take flock

	lea	$ffff8600.w,a0  ; DMA registers bank

	bsr.s	drv_a_selected  ; DRV A already deselected?
	tst.b	d0              ; If yes, return
	beq.s	.done

.wait	bsr	read_fdc_status ; Verify Motor On/Off
	btst	#7,d0           ; (status register, bit S7)
	bne.s	.wait

	moveq.l	#0,d0           ; Deselect DRV A
	bsr.s	fdc_select

.done	move.w	(a7)+,$43e.w    ; Restore flock

	movem.l	(a7)+,d0/a0
	rts

	;
	; send_ikbd()
	;
	; Send a command to the IKBD.
	;
	; In:
	;   d0: IKBD command
	;
send_ikbd:
	movem.l	d1-d2,-(a7)

	; Save the current interrupt mask.
	move	sr,d1
.poll	; Mask the interrupts.
	move	#$2700,sr
	; Check if the ACIA is ready to send data
	; (Tx data register empty).
	btst	#1,$fffffc00.w
	bne.s	.ready
	; ACIA is not ready yet.
	; Restore the interrupt mask and wait a bit.
	move	d1,sr
	move.w	#$600,d2
.wait	dbf	d2,.wait
	; Try again.
	bra.s	.poll
.ready	; ACIA is ready, send the command.
	move.b	d0,$fffffc02.w
	; Restore the interrupt mask.
	move	d1,sr
.flush	; Wait until the command has been actually sent.
	btst	#1,$fffffc00.w
	beq.s	.flush

	movem.l	(a7)+,d1-d2
	rts

	;
	; flush_acia()
	;
	; Flush the ACIA receive buffer.
	;
flush_acia:
	btst	#0,$fffffc00.w
	beq.s	.done
	tst.b	$fffffc02.w
	bra.s	flush_acia
.done	rts

	;
	; wait_acia()
	;
	; Wait until the IKBD is idle.
	; Make sure that all pending IKBD events are consumed
	; by the current IKBD interrupt handler.
	;
wait_acia:
	movem.l	d0-d1/a0,-(a7)
	move.w	$3fe.w,-(a7)

	; Hook the IKBD interrupt vector.
	; Each time an IKBD interrupt is triggered, a flag is
	; raised at address $3fe.
	lea	.isr_hook(pc),a0
	move.l	$118.w,(.isr_orig+2-.isr_hook)(a0)
	move.l	a0,$118.w

	; Wait until the IKBD is idle: at least 20 milliseconds
	; (4 timer C interruptions) must elapse without any
	; IKBD interruptions.
.again	sf.b	$3fe.w          ; Clear the flag
	move.l	$4ba.w,d0       ; Timer C counter (_hz_200)
	addq.l	#4,d0           ; 4 timer C periods = 20 ms
.wait	tst.b	$3fe.w          ; Any IKBD interrupt?
	bne.s	.again          ; Yes, let's start over
	move.l	d0,d1
	sub.l	$4ba.w,d1       ; Wait for 20 ms
	bpl.s	.wait

	; Restore the original IKBD interrupt vector.
	move.l	(.isr_orig+2-.isr_hook)(a0),$118.w

	move.w	(a7)+,$3fe.w
	movem.l	(a7)+,d0-d1/a0
	rts

.isr_hook
	; Indicate that an IKBD interrupt has occurred.
	st	$3fe.w
.isr_orig
	; Call the original IKBD handler.
	jmp	$0.l

	;
	; handle_acia()
	;
	; Make sure the IKBD is idle.
	; Consume pending IKBD events on our own.
	;
handle_acia:
	movem.l	d0-d1,-(a7)

	; Assume that the IKBD is idle if at least 20 milliseconds
	; (4 timer C interruptions) elapse without any IKBD events.
	bra.s	.start
.again	tst.b	$fffffc02.w     ; Consume the IKBD event
.start	move.l	$4ba.w,d0       ; Timer C counter (_hz_200)
	addq.l	#4,d0           ; 4 timer C periods = 20 ms
.wait	btst	#0,$fffffc00.w  ; Any IKBD event?
	bne.s	.again          ; Yes, let's start over
	move.l	d0,d1
	sub.l	$4ba.w,d1       ; Wait for 20 ms
	bpl.s	.wait

	movem.l	(a7)+,d0-d1
	rts

	;
	; save_mfp()
	;
	; Save the MFP configuration.
	;
save_mfp:
	move.l	a0,-(a7)

	lea	mfp_saved(pc),a0
	move.b	$fffffa07.w,(a0)+   ; Enable A
	move.b	$fffffa09.w,(a0)+   ; Enable B
	move.b	$fffffa13.w,(a0)+   ; Mask A
	move.b	$fffffa15.w,(a0)+   ; Mask B
	move.b	$fffffa17.w,(a0)+   ; Vector register

	movea.l	(a7)+,a0
	rts

	;
	; stop_mfp()
	;
	; Shut down the MFP.
	;
stop_mfp:
	; Stop all timers.
	clr.b	$fffffa19.w         ; Timer A
	clr.b	$fffffa1b.w         ; Timer B
	clr.b	$fffffa1d.w         ; Timers C & D

	; Disable MFP A & B channels.
	clr.b	$fffffa07.w         ; Enable A
	clr.b	$fffffa13.w         ; Mask A
	clr.b	$fffffa09.w         ; Enable B
	clr.b	$fffffa15.w         ; Mask B

	; Clear pending interrupts.
	clr.b	$fffffa0b.w         ; Pending A
	clr.b	$fffffa0f.w         ; In-service A
	clr.b	$fffffa0d.w         ; Pending B
	clr.b	$fffffa11.w         ; In-service B
	rts

	;
	; restore_mfp()
	;
	; Restore the MFP configuration.
	;
restore_mfp:
	move.l	a0,-(a7)

	bsr.s	stop_mfp            ; Disable MFP ints

	; Restore MFP A & B.
	lea	mfp_saved(pc),a0
	move.b	(a0)+,$fffffa07.w   ; Enable A
	move.b	(a0)+,$fffffa09.w   ; Enable B
	move.b	(a0)+,$fffffa13.w   ; Mask A
	move.b	(a0)+,$fffffa15.w   ; Mask B
	move.b	(a0)+,$fffffa17.w   ; Vector register

	bsr.s	setup_timerc        ; Enable timer C

	movea.l	(a7)+,a0
	rts

	;
	; setup_timerc()
	;
	; Set up and enable timer C.
	; Timer C Frequency = 2457600 / 64 / 192 = 200Hz.
	;
setup_timerc:
	clr.b	$fffffa1d.w      ; Timer C/D Ctrl = stop
	bset.b	#5,$fffffa09.w   ; Timer C Enable
	bset.b	#5,$fffffa15.w   ; Timer C Int Mask
	bclr.b	#5,$fffffa11.w   ; Timer C In-service
	move.b	#192,$fffffa23.w ; Timer C Data = 192
	move.b	#$50,$fffffa1d.w ; Timer C Ctrl = div by 64
	rts

	;
	; ints_safe()
	;
	; Disable all interrupts and keep a basic timer C that
	; only updates _hz_200 ($4ba).
	;
	; - Auto-Vector interrupts are disabled by installing
	;   a dummy handler (which just returns).
	; - MFP interrupts (User-assigned) are disabled on the
	;   MFP. A dummy handler is also installed for each of
	;   them.
	;
	; The basic timer C is used when executing ints_off()
	; in order to wait for pending IKBD events to be consumed.
	; This timer C is installed because we don't want to use
	; the system timer that could be broken when ints_off()
	; is called (at the end of the "ripping" work).
	;
ints_safe:
	move.l	a0,-(a7)

	; Disable CPU interrupts.
	move.w	#$2700,sr

	; $6c contains a dummy interrupt handler which
	; merely returns (rte).
	lea	$6c.w,a0
	move.w	#$4e73,(a0)     ; rte

	; Install the dummy handler for Auto-Vector interrupts.
	move.l	a0,$68.w        ; HBL
	move.l	a0,$70.w        ; VBL
	move.l	a0,$78.w        ; MFP

	; Install the dummy handler for User-assigned interrupts.
	move.l	a0,$100.w       ; Centronics Busy
	move.l	a0,$104.w       ; RS-232 DCD
	move.l	a0,$108.w       ; RS-232 CTS
	move.l	a0,$10c.w       ; Blitter
	move.l	a0,$110.w       ; Timer D
	move.l	a0,$118.w       ; IKBD/ACIA
	move.l	a0,$11c.w       ; FDC
	move.l	a0,$120.w       ; Timer B (HBL)
	move.l	a0,$124.w       ; RS-232 TX Error
	move.l	a0,$128.w       ; RS-232 TX Empty
	move.l	a0,$12c.w       ; RS-232 RX Error
	move.l	a0,$130.w       ; RS-232 RX Full
	move.l	a0,$134.w       ; Timer A
	move.l	a0,$138.w       ; RS-232 Ring Detect
	move.l	a0,$13c.w       ; MFP-15: Monochrome Detect

	; Install our own timer C handler, which only updates
	; _hz_200 ($4ba).
	lea	timerc_simple(pc),a0
	move.l	a0,$114.w       ; Timer C

	; Disable MFP interrupts.
	bsr	stop_mfp

	; Re-enable timer C.
	bsr	setup_timerc

	; Re-enable CPU interrupts.
	move.w	#$2300,sr

	movea.l	(a7)+,a0
	rts

	;
	; ints_off()
	;
	; Disable CPU interrupts after IKBD has been smoothly
	; stopped (making sure that all pending IKBD events
	; have been processed).
	;
	; In:
	;   a0: routine called to process pending IKBD events
	;       (either we consume these events on our own or
	;       we wait for the TOS to process them)
	;
ints_off:
	move.l	d0,-(a7)

	; Disable the mouse.
	moveq.l	#$12,d0
	bsr	send_ikbd

	; Disable the joystick.
	moveq.l	#$15,d0
	bsr	send_ikbd

	; Handle pending IKBD events on our own, or wait for
	; the TOS to process them.
	jsr	(a0)

	; Pause IKBD transfers.
	moveq.l	#$13,d0
	bsr	send_ikbd

	; Handle pending IKBD events on our own, or wait for
	; the TOS to process them.
	jsr	(a0)

	; Disable CPU interrupts.
	move.w	#$2700,sr

	; Flush the ACIA buffer.
	bsr	flush_acia

	move.l	(a7)+,d0
	rts

	;
	; ints_on()
	;
	; Re-enable CPU interrupts and resume IKBD.
	;
ints_on:
	move.l	d0,-(a7)

	; Flush the ACIA buffer.
	bsr	flush_acia

	; Re-enable CPU interrupts.
	move.w	#$2300,sr

	; Resume IKBD transfers.
	moveq.l	#$11,d0
	bsr	send_ikbd

	move.l	(a7)+,d0
	rts

	;
	; FIX_INTERRUPTS()
	;
	; Disable interrupts that are not supposed to occur
	; when the bootsector is running.
	;
	; This macro is used in two places:
	; - In this program, when a sandbox is created to execute
	;   the bootsector.
	; - In the preamble code, when a suitable execution
	;   environment is set up to run the cracktro.
	; In both cases, the objective is to set up an execution
	; environment similar to the one in which the bootsector
	; (and thus the cracktro) is executed by the TOS.
	; In such environment, only a limited number of interrupts
	; is supposed to occur.
	;
	; In:
	;   param1: dummy exception handler (rte)
	;
	; Out:
	;   Only the VBL, IKBD/ACIA and timer C interrupts are
	;   still enabled.
	;
	; Scratch: d0/a0
	;
FIX_INTERRUPTS	macro

	; MFP register bank.
	lea	$fffffa00.w,a0

	; Stop all timers, keep timer C.
	clr.b	$19(a0)            ; Timer A
	clr.b	$1b(a0)            ; Timer B
	andi.b	#%01110000,$1d(a0) ; Timers C & D

	; Disable all MFP channels, keep IKBD/ACIA and timer C.
	clr.b	$7(a0)             ; Enable A
	clr.b	$13(a0)            ; Mask A
	andi.b	#%01100000,$9(a0)  ; Enable B
	andi.b	#%01100000,$15(a0) ; Mask B

	; Clear pending interrupts, keep IKBD/ACIA and timer C.
	clr.b	$b(a0)             ; Pending A
	clr.b	$f(a0)             ; In-service A
	andi.b	#%01100000,$d(a0)  ; Pending B
	andi.b	#%01100000,$11(a0) ; In-service B

	; Install a dummy handler for all interrupt vectors,
	; keep the VBL, IKBD/ACIA and timer C.
	move.l	\1,$68.w           ; HBL
	move.l	\1,$78.w           ; MFP
	move.l	\1,$100.w          ; Centronics Busy
	move.l	\1,$104.w          ; RS-232 DCD
	move.l	\1,$108.w          ; RS-232 CTS
	move.l	\1,$10c.w          ; Blitter
	move.l	\1,$110.w          ; Timer D
	move.l	\1,$11c.w          ; FDC
	move.l	\1,$120.w          ; Timer B (HBL)
	move.l	\1,$124.w          ; RS-232 TX Error
	move.l	\1,$128.w          ; RS-232 TX Empty
	move.l	\1,$12c.w          ; RS-232 RX Error
	move.l	\1,$130.w          ; RS-232 RX Full
	move.l	\1,$134.w          ; Timer A
	move.l	\1,$138.w          ; RS-232 Ring Detect
	move.l	\1,$13c.w          ; Monochrome Detect

	; Disable user-defined VBL routines.
	movea.l	$456.w,a0          ; _vblqueue
	move.w	$454.w,d0          ; nvbls
	subq.w	#1,d0
.c_vblq	clr.l	(a0)+
	dbf	d0,.c_vblq

	endm

LINEF_TRAMP_SIZE   =	$50

	;
	; FIX_LINEF()
	;
	; Move the GEM Line-F handler to a safe place.
	;
	; On STf, the Line-F exception is used by the TOS
	; (version 1.00, 1.02 and 1.04) for internal subroutine
	; calls.
	; Originally, it was used to squeeze the TOS into 192
	; KB of ROM: instead of using a standard BSR or JSR
	; instruction, which is 4 or 6 bytes, $Fxxx opcodes
	; (2 bytes only) and a Line-F dispatcher were used to
	; call internal subroutines.
	;
	; When the GEM starts, it installs an optimized Line-F
	; handler in low user memory (which uses self-modifiable
	; code).
	; This handler can be corrupted when executing the
	; bootsector or the boot cracktro as both are allowed
	; to use the entire low user memory.
	; If this happens, the TOS is merely broken.
	;
	; To prevent the Line-F handler from being corrupted,
	; it is moved to a safe location.
	;
	; This macro is used in two places:
	; - In this program, when a sandbox is created to execute
	;   the bootsector.
	; - In the preamble code, when a suitable execution
	;   environment is set up to run the cracktro.
	; In both cases, the objective is to set up an execution
	; environment similar to the one in which the bootsector
	; (and thus the cracktro) is executed by the TOS.
	; In such environment, the Line-F handler should not
	; reside in the memory area used by the bootsector.
	;
	; In:
	;   param1: fatal error handler installed for the Line-F
	;           exception (used only on STe, on which the TOS
	;           does not use the Line-F)
	;   param2: buffer located in a safe area, which will
	;           contain the GEM Line-F handler to be moved
	;           (used on STf only)
	;
	; Scratch: d0-d1,a0-a2
	;
FIX_LINEF	macro

	lea	\1,a0         ; a0 = fatal error handler
	move.l	$2c.w,d0      ; Line-F exception handler
	andi.l	#$00ffffff,d0 ; Keep the lower 24 bits
	movea.l	d0,a2         ;
	cmpa.l	$42e.w,a2     ; Line-F handler is in RAM?
	bhs.s	.set_lf       ; No? (STe), ignore it
	lea	\2,a1         ; Yes (STf), move it
	movea.l	a1,a0         ; a0 = new handler address
	move.w	#(LINEF_TRAMP_SIZE/2)-1,d0
.cp_lf	move.w	(a2)+,d1      ;
	move.w	d1,(a1)+      ;
	cmpi.w	#$4e75,d1     ; The handler ends with a RTS
	dbeq	d0,.cp_lf     ;
	tst.w	d0            ; Handler correctly moved?
	bmi.s	.end_lf       ; No? Don't update the vector
.set_lf	move.l	a0,$2c.w      ; STf: install the new hdl
		              ; STe: install the error hdl
.end_lf
	endm

	;
	; FIX_CURR_BPAGE()
	;
	; Patch the TOS variable that points to the current
	; GEMDOS process (more precisely that points to the
	; corresponding basepage).
	;
	; The TOS maintains a global variable (in low memory)
	; that points to the basepage of the current process.
	; Each time a call to the GEMDOS is made (Trap #1),
	; this variable is read to know the address of the
	; current process's basepage in order to execute the
	; GEMDOS call on behalf of this process.
	;
	; When the bootsector and the cracktro it loads are
	; executed by the TOS at boot time, no process is running
	; in the system yet and the TOS variable mentioned above
	; points to the initial basepage (the root basepage).
	; Thus, any call to a GEMDOS service made by the boot
	; sector or by the boot cracktro is made in the name of
	; the initial basepage.
	; This basepage is located very low in memory and is
	; therefore protected from memory accesses by the
	; bootsector or the cracktro.
	;
	; But when the ripped cracktro is executed from the GEM,
	; the current process is the cracktro PRG itself and
	; the TOS variable points to its basepage.
	; This basepage is thus located in the standard user
	; memory which can be corrupted by the cracktro
	; (because the cracktro expects to be executed by the
	; bootsector from a low user memory address and assumes
	; that it can access most of the user memory).
	; If this happens, any call to a GEMDOS service will
	; merely crash the system.
	; 
	; To prevent the GEMDOS from using a corrupted basepage,
	; the TOS variable pointing to the current process's
	; basepage is modified so that it points to the initial
	; basepage, as it does at boot time.
	;
	; This macro is used in two places:
	; - In this program, when a sandbox is created to execute
	;   the bootsector (because the bootsector can also corrupt
	;   the current basepage and still call the GEMDOS).
	; - In the preamble code, when a suitable execution
	;   environment is set up to run the cracktro.
	; In both cases, the objective is to set up an execution
	; environment similar to the one in which the bootsector
	; (and thus the cracktro) is executed by the TOS.
	; In such environment, the current basepage that is pointed
	; to by the TOS variable is the initial basepage.
	;
	; To locate the initial basepage, we proceed as follows:
	; Each basepage contains a pointer to its parent base
	; page. The basepages are therefore chained from the
	; current basepage to the initial basepage via the parent
	; pointer. The initial basepage is the only one that is
	; at the very bottom of the memory, before the start of
	; the user memory (before _membot). To find it, we simply
	; start from the current basepage and walk through the
	; "parent" pointers until the initial basepage is reached.
	;
	; Locating the TOS variable that points to the current
	; basepage is a bit more complicated and depends on the
	; version of the TOS.
	; From version 1.02 of the TOS, a pointer to this variable
	; is provided in the OSHEADER structure (structure whose
	; address is provided in $4f2).
	; But early TOS (version < 1.02) do not provide this
	; information. So, to find the variable, the following
	; heuristic is used: the variable resides in low memory
	; just before the header of the 8x16 system font.
	; The '8x16' pattern is therefore searched in low memory,
	; then the address of the current basepage is searched
	; in the few bytes preceding the font header.
	; Note that this heuristic does not only work for old TOS
	; but actually for all TOS except EmuTOS.
	;
	; In:
	;   param1: pointer to this program's basepage; it will
	;           be used to get back to the initial basepage
	;
	; Out:
	;   a0: initial basepage
	;   a1: address of the TOS variable that points to the
	;       current basepage, or NULL if not found
	;   (a1): the TOS variable (if found) has been patched
	;         to point to the initial basepage
	;
	; Scratch: d0-d2/a0-a2
	;
FIX_CURR_BPAGE	macro

	; 1) Find the initial basepage.
	move.l	\1,d0         ; Current prog's basepage
	move.l	$432.w,d1     ; Start of user memory
	movea.l	d0,a0         ;
.s_root	movea.l	$24(a0),a0    ; Get the parent basepage
	cmp.l	a0,d1         ;  until the initial basepage
	bls.s	.s_root       ;  is reached (< user memory)
	; 2) Find the TOS variable.
	movea.l	$4f2.w,a1     ; a1 = OSHEADER (SYSHDR)
	movea.l	8(a1),a1      ; Real OS base address
	cmpi.w	#$102,2(a1)   ; TOS version < 1.02?
	blt.s	.oldtos       ; Yes? take the slow path
	movea.l	$28(a1),a1    ; No? get OSHEADER->p_run
	bra.s	.fix_bp       ;  and skip the slow path
.oldtos	movea.l	d1,a1         ; Slow path (TOS < 1.02)
	lea	$5b0.w,a2     ; Lower limit for pattern search
	move.l	#'8x16',d1    ; Pattern to search
.s_font	cmp.l	(a1),d1       ; Search the pattern backwards
	beq.s	.s_bp1        ;  from the beginning of the
	subq.l	#2,a1         ;  user memory to the lower
	cmpa.l	a1,a2         ;  limit ($5b0)
	blo.s	.s_font       ; 
	suba.l	a1,a1         ; Pattern not found,
	bra.s	.end_bp       ;  stop here with a1 = 0
.s_bp1	moveq.l	#7,d2         ; Pattern found,
	lea	-(8*2+2)(a1),a1
.s_bp2	addq.l	#2,a1         ;  now search the address
	cmp.l	(a1),d0       ;  of current prog's basepage
	beq.s	.fix_bp       ; Finish if address found
	dbf	d2,.s_bp2     ;
	bra.s	.s_font       ; Otherwise, continue search
.fix_bp	; 3) Patch the TOS variable to point to
	;    the initial basepage.
	;    a0 = address of the initial basepage
	;    a1 = address of the TOS variable
	move.l	a0,(a1)       ; Patch the TOS variable
.end_bp
	endm

	; Lowest possible address that can be accessed without
	; overwriting critical TOS data, especially the variable
	; that points to the current basepage (OSHEADER->p_run).
	; This address is valid under all TOS versions and has
	; been determined using the value of OSHEADER->p_run
	; under TOS 1.04.
MEMBOT_MIN =	$8800
	; _membot value chosen to be valid under all TOS versions.
	; It is used in the sandbox and preamble code.
MEMBOT     =	$e000

	;
	; setup_lowmem()
	;
	; Create a special execution environment, called a sandbox,
	; that allows the bootsector to be safely executed in low
	; user memory as if it were running at boot time. In this
	; sandbox, the bootsector can trash the memory used by the
	; GEM without consequences (the GEM allocates the first
	; 32 KB of low user memory, starting at _membot).
	;
	; To this end, several services set up by the GEM after
	; boot are disabled in order to return to a runtime
	; environment similar to the one at boot. This is the
	; same process used by the preamble code to make the
	; boot-cracktro executable from the GEM.
	;
	; 1) This routine saves the current execution environment
	; so that it can be restored once the bootsector has been
	; executed and the cracktro has been ripped.
	; This consists in:
	; - The low memory. Indeed, the user area between _membot
	;   and $80000 is fully allocated to the bootsector to
	;   load and execute the cracktro.
	;   The low memory is saved in the high memory area
	;   determined by the check_mem() routine.
	; - The MFP registers.
	; - The video palette.
	;
	; 2) Then it creates an execution environment that is
	; suitable for the bootsector and the cracktro, i.e.
	; similar to the one used by the TOS at boot time to
	; run the bootsector (and thus the cracktro):
	; - Disables the Line-A as it is not available at
	;   boot-time.
	; - Disables interrupts that are not supposed to occur
	;   when the bootsector is running.
	; - Moves the GEM Line-F handler to a safe place.
	; - Patches the TOS variable that points to the current
	;   basepage to make it point to the initial basepage.
	; - Hooks the GEMDOS vector to catch the functions that
	;   cannot be executed in the sandbox.
	; - Disables the AES/VDI.
	; - Disables the mouse on the IKBD and replaces the VDI
	;   mouse handler with a dummy handler.
	; - Disables the GEM Event timer handler ($400).
	; - Disables the GEM Critical error handler (404).
	; - Disables Hard Disk Driver ops ($46a-$47e).
	; - Hides Hard Disk units and forces the boot device to
	;   DRV A.
	; - Modifies the system variables to simulate a machine
	;   with only 512 KB of RAM and a low-resolution screen.
	; - Clears the low user memory.
	; - Set up the Shifter Video Controller (low-resolution,
	;   screen address and low-rez video palette).
	;
	; 3) In addition, it installs a fatal error handler for all
	; CPU exceptions, in order to catch any fault that might
	; occur when running the bootsector.
	;
setup_lowmem:
	movem.l	d0-d7/a0-a3,-(a7)

	; The key that was pressed to start loading and executing
	; the bootsector will most likely be released after the
	; execution environment has been saved (using this routine)
	; and certainly before the "ripping" work is completed
	; and the original execution environment is restored.
	; Thus, this keystroke event will not be present in the
	; saved environment and will therefore be missing when this
	; environment is restored, leading the TOS to consider that
	; the key has not been released and that auto-repeat must
	; be enabled.
	; To prevent unwanted key auto-repeat from occurring, the
	; key auto-repeat mode is disabled immediately, before
	; saving the execution environment.
	bclr.b	#1,$484.w

	; Disable CPU interrupts after IKBD has been smoothly
	; stopped, making sure that all pending IKBD events
	; have been processed.
	; Pending IKBD events are consumed by the TOS so that the
	; character buffer (located in low memory) is updated
	; before the low memory is saved.
	lea	wait_acia(pc),a0
	bsr.s	ints_off

	; Reset the current state of the keyboard 'special' keys.
	clr.w	-(a7)
	move.w	#$b,-(a7)
	trap	#13
	addq.l	#4,a7

	; Save the MFP configuration.
	bsr	save_mfp

	; Save the video palette.
	lea	pal_saved(pc),a0
	movem.l	$ffff8240.w,d0-d7
	movem.l	d0-d7,(a0)

	; Save the low memory.
	; See the check_mem() routine for the details on how the
	; lowmem_buf_rel and lowmem_size variables are determined.
	lea	$8.w,a0
	movea.l	lowmem_buf_rel(pc),a1
	move.l	lowmem_size(pc),d0
	bsr	mcopy

	; Find a dummy exception handler in ROM (i.e. a single
	; 'rte' instruction) which will be used to disable
	; unwanted exceptions.
	; Using a handler in ROM is the best way to defeat
	; protections that check the contents of the vectors.
	movea.l	$4f2.w,a3       ; OSHEADER (SYSHDR)
	movea.l	8(a3),a3        ; Real OS base address
.romrte	cmpi.w	#$4e73,(a3)+    ; Find a 'rte' in ROM
	bne.s	.romrte
	subq.l	#2,a3           ; Dummy exception handler

	; Install a fatal error handler for all CPU exceptions,
	; in order to catch any fault that might occur when
	; running the bootsector.
	lea	exec_boot_err(pc),a0
	lea	$8.w,a1
	moveq.l	#7,d0
.s_err	move.l	a0,(a1)+
	dbf	d0,.s_err

	; Ignore "Zero Divide" exceptions.
	move.l	a3,$14.w        ; Divide by Zero

	; Disable the Line-A as it is not available at boot-time.
	lea	linea_void(pc),a0
	move.l	a0,$28.w        ; Line-A

	; Disable interrupts that are not supposed to occur
	; when the bootsector is running.
	FIX_INTERRUPTS	a3

	; Debug mode only: install our own timer C handler.
	; (useful when debugging under MonST which has a
	; timer C handler running in low memory).
	ifne	DBG_SAFE_TIMERC
	lea	timerc_simple(pc),a0
	move.l	a0,$114.w       ; Timer C
	endc

	; Move the GEM Line-F handler to a safe place.
	FIX_LINEF	exec_boot_err(pc),linef(pc)

	; Patch the TOS variable that points to the current
	; basepage to make it point to the initial basepage.
	FIX_CURR_BPAGE	basepage(pc)
	; At the end of the macro, a1 = address of the TOS
	; variable or NULL if not found.

	; Save the address of the TOS variable.
	lea	tos_curr_basepage(pc),a0
	move.l	a1,(a0)

	; Hook the GEMDOS vector (Trap #1) in order to:
	; - Completely disable the GEMDOS if the TOS variable that
	;   points to the current basepage could not be patched.
	; - Stop the execution of the bootsector if it calls a
	;   GEMDOS function that cannot be executed in the sandbox
	;   (i.e. any file, directory, memory or process function).
	lea	trap1_hook(pc),a0
	move.l	$84.w,(trap1_jmp+2-trap1_hook)(a0)
	move.l	a0,$84.w        ; Trap #1

	; Disable the AES/VDI (Trap #2) since it is not supposed
	; to be used by the bootsector.
	lea	trap_enosys(pc),a0
	move.l	a0,$88.w        ; Trap #2

	; Disable the mouse and especially force the XBios to
	; install a dummy interrupt handler (simple rts) in the
	; internal mouse vector.
	; This ensures that the mouse handler previously installed
	; by the VDI, which could corrupt the low user memory used
	; by the bootsector, will no longer be called.
	; Note that the mouse was already disabled on the IKBD
	; by ints_off(), so this is an additional measure in case
	; the mouse is physically re-enabled by the bootsector.
	clr.l	-(a7)           ; Vec ignored when type=0
	clr.l	-(a7)           ; Par ignored when type=0
	move.w	#0,-(a7)        ; Type = 0 = Disable mouse
	move.w	#0,-(a7)        ; Initmouse
	trap	#14
	lea	12(a7),a7

	; Disable the GEM Event timer handler.
	lea	gem_event_timer_void(pc),a0
	move.l	a0,$400.w       ; GEM Event timer handler

	; Disable the GEM Critical error handler.
	lea	gem_crit_error(pc),a0
	move.l	a0,$404.w       ; GEM Critical error hdl

	; Disable Hard Disk Driver ops.
	lea	hdv_enosys(pc),a0
	move.l	a0,$46a.w       ; hdv_init
	move.l	a0,$476.w       ; hdv_rw
	move.l	a0,$47a.w       ; hdv_boot
	move.l	a0,$47e.w       ; hdv_mediach
	lea	hdv_null(pc),a0
	move.l	a0,$472.w       ; hdv_bpb

	; Hide Hard Disk units and force the boot device to DRV A.
	clr.w	$446.w          ; _bootdev
	move.w	#1,$4a6.w       ; _nflops
	move.l	#3,$4c2.w       ; _drvbits

	;
	; Modify the system variables to simulate a machine
	; with only 512 KB of RAM and a low-resolution screen.
	;

	lea	$78000,a0       ; New screen address
	lea	$80000,a1       ; New memory end address
	movea.l	$4f2.w,a2       ; Original _sysbase

	clr.l	$420.w          ; memvalid
	move.b	#4,$424.w       ; memctrl
	clr.l	$426.w          ; resvalid
	move.l	a1,$42e.w       ; phystop
	move.l	a0,$436.w       ; _memtop
	clr.l	$43a.w          ; memval2
	clr.b	$44c.w          ; sshiftmod
	move.l	a0,$44e.w       ; _v_bas_ad
	clr.l	$45a.w          ; colorptr
	clr.l	$45e.w          ; screenpt
	move.l	a1,$4f2.w       ; _sysbase
	clr.l	$51a.w          ; memval3

	; Clear the low user memory.
	movea.l	$432.w,a0       ; _membot
	move.l	#$80000,d0
	sub.l	a0,d0
	lsr.l	#4,d0
.c_lmem	clr.l	(a0)+
	clr.l	(a0)+
	clr.l	(a0)+
	clr.l	(a0)+
	dbf	d0,.c_lmem

	; Copy the original OSHEADER to the new _sysbase.
	; This is done on purpose after the above loop to prevent
	; the first bytes of the OSHEADER copy from being cleared
	; when clearing the low user memory.
	moveq.l	#(48/4)-1,d0
.syshdr	move.l	(a2)+,(a1)+
	dbf	d0,.syshdr

	ifne	DBG_SELFTESTS
	lea	in_selftest(pc),a0
	tst.b	(a0)
	beq.s	.membot
	; In the sandbox, _membot is set up to a new value that
	; is valid under all TOSes (see below for a detailed
	; explanation).
	; But during selftests, _membot is not redefined unless
	; its original value is higher than this new value.
	; This allows the robustness tests to corrupt the low user
	; memory starting from the lowest possible but still valid
	; value.
	; In addition, make sure the configuration of the Shifter
	; Video Controller is not modified during selftests.
	cmpi.l	#MEMBOT,$432.w
	bls.s	.int_on
	move.l	#MEMBOT,$432.w  ; _membot
	move.l	$432.w,$4fa.w   ; end_os
	bra.s	.int_on
	endc	; DBG_SELFTESTS

	; Sometimes the cracktro is loaded by the bootsector at
	; the address pointed to by the variable _membot ($432).
	; But the value of _membot varies depending on the TOS
	; version and the value found under one TOS may be too
	; low and therefore invalid under another TOS.
	; Since this address is hard-coded in the preamble code
	; (as the execution address), it can make the cracktro
	; ripped under one TOS incompatible with another TOS.
	; To overcome this, the variable _membot is redefined
	; in the sandbox to a new value that is valid under all
	; TOS versions.
	;
	; Here are the values of _membot for different TOS
	; versions:
	; 1.00: $a100
	; 1.02: $ca00
	; 1.04: $a84e
	; 1.06: $a892
	; 1.62: $a892
	; 2.05: $c8ae
	; 2.06: $ccb2
	;
.membot	move.l	#MEMBOT,$432.w  ; _membot
	move.l	$432.w,$4fa.w   ; end_os

	; Set up the Shifter Video Controller:
	; screen address and low-resolution.
	move.b	$44f.w,$ffff8201.w
	move.b	$450.w,$ffff8203.w
	move.b	$451.w,$ffff820d.w
	move.b	$44c.w,$ffff8260.w

	; Set up the Shifter Video Controller:
	; low-rez video palette.
	movem.l	pal_low(pc),d0-d7
	movem.l	d0-d7,$ffff8240.w

	; Re-enable CPU interrupts and resume IKBD.
.int_on	bsr	ints_on

	bsr	vsync

	ifne	DBG_SELFTESTS
	tst.b	(a0)
	bne.s	.ret
	endc	; DBG_SELFTESTS

	; Inform the XBios about the new screen configuration.
	clr.w	-(a7)
	move.l	$44e.w,-(a7)
	move.l	$44e.w,-(a7)
	move.w	#5,-(a7)
	trap	#14
	lea	12(a7),a7

	bsr	vsync

.ret	movem.l	(a7)+,d0-d7/a0-a3
	rts

	;
	; restore_lowmem()
	;
	; Restore the execution environment that had been saved
	; by the setup_lowmem() routine.
	; This routine is called once the "ripping" work is
	; complete in order to destroy the sandbox and restore
	; the original execution environment.
	;
restore_lowmem:
	movem.l	d0-d7/a0-a2,-(a7)

	; Disable all interrupts and keep a basic timer C that
	; only updates _hz_200.
	bsr	ints_safe

	; Take flock.
	st	$43e.w

	; If the floppy disk has been accessed by the bootsector
	; (i.e. Floprd was called) then seek drive A to track 0
	; in order to restore the state of drive A as it was
	; before the creation of the sandbox.
	; This is required on EmuTOS which caches the current
	; track and does not systematically execute a seek
	; track command.
	move.l	trap14_buf_next(pc),d0
	beq.s	.noseek
	bsr	seek_track0
.noseek
	; Disable CPU interrupts after IKBD has been smoothly
	; stopped, making sure that all pending IKBD events
	; have been processed.
	; Pending IKBD events are consumed by the handle_acia()
	; routine. The TOS does not need to be informed about
	; pending IKBD events because the low memory (including
	; the character buffer) will be fully restored.
	lea	handle_acia(pc),a0
	bsr	ints_off

	; Tell the PSG to shut up (use shadow registers).
	lea	$ffff8800.w,a0
	move.l	#$08080000,(a0)
	move.l	#$09090000,(a0)
	move.l	#$0a0a0000,(a0)

	; Restore the low memory.
	movea.l	lowmem_buf_rel(pc),a0
	lea	$8.w,a1
	move.l	lowmem_size(pc),d0
	bsr	mcopy

	; Restore the Shifter Video Controller settings.
	move.b	$44f.w,$ffff8201.w
	move.b	$450.w,$ffff8203.w
	move.b	$451.w,$ffff820d.w
	move.b	$44c.w,$ffff8260.w

	movem.l	pal_saved(pc),d0-d7
	movem.l	d0-d7,$ffff8240.w

	; Restore the MFP configuration.
	bsr	restore_mfp

	; Reset the current state of the keyboard 'special' keys.
	clr.w	-(a7)
	move.w	#$b,-(a7)
	trap	#13
	addq.l	#4,a7

	; Re-enable CPU interrupts and resume IKBD.
	bsr	ints_on

	; Re-enable the mouse.
	moveq.l	#$8,d0
	bsr	send_ikbd

	; Wait for drive A to shut down and deselect the drive.
	bsr	fdc_deselect

	bsr	vsync

	; Release flock.
	sf	$43e.w

	movem.l	(a7)+,d0-d7/a0-a2
	rts

	;
	; timerc_simple()
	;
	; Basic timer C handler which only updates _hz_200 ($4ba).
	;
	; It is used when executing ints_off() in order to wait
	; for pending IKBD events to be consumed.
	; This timer C is installed because we don't want to use
	; the system timer that could be broken when ints_off()
	; is called (at the end of the "ripping" work).
	;
timerc_simple:
	addq.l	#1,$4ba.w       ; _hz_200
	btst	#3,$fffffa17.w  ; Support both
	beq.s	.ret            ;  the automatic EOI
	bclr.b	#5,$fffffa11.w  ;  and the software EOI
.ret	rte

	;
	; timerc_hook()
	;
	; Timer C Hook, providing a watchdog timer.
	;
	; The original timer C handler is intercepted using the
	; following hook in order to provide a watchdog timer.
	; This watchdog timer is used to monitor the activity of
	; the bootsector and in particular to check that sectors
	; are regularly loaded until the cracktro is detected.
	; The watchdog is kicked by the Trap #14 post-hook (see
	; the trap14_post() routine).
	; So, as long as the Trap #14 is used by the bootsector
	; (to load sectors), the watchdog timer will not time out.
	; But if the watchdog is not kicked for BOOT_TIMEOUT
	; seconds (Trap #14 is no longer used or not used at all)
	; and no cracktro has been detected, the watchdog will
	; time out and control will be returned to the program.
	;
timerc_hook:
	movem.l	d0/a0,-(a7)

	; Check if the timer-C-based watchdog timer has been
	; kicked within the last BOOT_TIMEOUT seconds.
	lea	timecounters(pc),a0
	addq.w	#1,(a0)
	move.w	(a0),d0
	sub.w	(timestamps-timecounters)(a0),d0
	cmpi.w	#(BOOT_TIMEOUT*200),d0
	blo.s	.ret

	; The watchdog timer timed out.
	; Modify the stack frame to return to the exec_boot_err()
	; routine.
	lea	exec_boot_err(pc),a0
	move.l	a0,(4+4+2)(a7)
	move.w	sr,(4+4+0)(a7)

	; Call the original timer C handler.
.ret	movem.l	(a7)+,d0/a0
timerc_jmp:
	jmp	$0.l

	;
	; vbl_hook()
	;
	; VBL Hook, providing a second watchdog timer.
	;
	; The original VBL handler is intercepted using the
	; following hook in order to provide a second watchdog
	; timer used to monitor the activity of the bootsector.
	;
	; The VBL watchdog works exactly like the timer C watchdog
	; and is only there to provide a double protection against
	; losing control of the bootsector's activity.
	;
vbl_hook:
	movem.l	d0/a0,-(a7)

	; Check if the VBL-based watchdog timer has been kicked
	; within the last BOOT_TIMEOUT seconds.
	lea	timecounters+2(pc),a0
	addq.w	#1,(a0)
	move.w	(a0),d0
	sub.w	(timestamps-timecounters)(a0),d0
	cmpi.w	#(BOOT_TIMEOUT*50),d0
	blo.s	.ret

	; The watchdog timer timed out.
	; Modify the stack frame to return to the exec_boot_err()
	; routine.
	lea	exec_boot_err(pc),a0
	move.l	a0,(4+4+2)(a7)
	move.w	sr,(4+4+0)(a7)

	; Call the original VBL handler.
.ret	movem.l	(a7)+,d0/a0
vbl_jmp:
	jmp	$0.l

	;
	; gem_event_timer_void()
	;
	; Dummy GEM Event timer handler ($400).
	;
	; It is installed to disable GEM periodic event handling,
	; as the original handler can corrupt the low user memory
	; used by the cracktro (in particular on EmuTOS).
	; Note that installing this dummy handler is not a problem
	; as GEM events are not used at boot time.
	;
gem_event_timer_void:
	rts

	;
	; gem_crit_error()
	;
	; Dummy GEM Critical error handler ($404).
	;
	; Mimic the handler installed at boot-time: simply
	; return an error code.
	;
gem_crit_error:
	moveq.l	#-1,d0
	rts

	;
	; linea_void()
	;
	; Dummy Line-A handler.
	;
	; The Line-A is not available at boot-time, so it is
	; disabled in the sandbox by installing this handler.
	;
linea_void:
	movea.l	2(a7),a0        ; Line-A instr address
	tst.b	1(a0)           ; Line-A opcode
	bne.s	.ret
	moveq.l	#0,d0           ; Special $a000 case:
	movea.l	d0,a0           ;  return NULL pointers
	movea.l	d0,a1
	movea.l	d0,a2
.ret	addq.l	#2,2(a7)        ; Skip the Line-A instr
	rte

	;
	; hdv_enosys()
	; hdv_null()
	;
	; Dummy handlers for the hard disk vectors ($46a-$47e).
	;
	; When the floppy disk bootsector is executed under normal
	; circumstances (i.e. at boot time), the hard disk vectors
	; contain the original Bios handlers.
	; But when the bootsector is executed by this program,
	; a resident hard disk driver may have installed its own
	; handlers and these may be invoked if the bootsector
	; performs Bios disk operations (Getbpb, Mediach or Rwabs).
	; This can be a problem because the resident hard disk
	; driver may be corrupted by the bootsector when loading
	; the cracktro.
	; In order to workaround this issue, this program does the
	; following:
	; - A dummy handler is installed for all hard disk vectors.
	;   It is either hdv_enosys() for functions returning an
	;   error code, or hdv_null() for functions returning a
	;   pointer (typically Getbpb).
	; - The Bios vector (Trap #13) is hooked so that disk ops
	;   (Getbpb, Mediach and Rwabs) are "emulated" directly by
	;   the hook routine (see trap13_hook).
	;
hdv_enosys:
	moveq.l	#-32,d0         ; ENOSYS
	bra.s	hdv_ret
hdv_null:
	moveq.l	#0,d0           ; NULL

	; During a Bios disk operation (Trap #13), the appropriate
	; hard disk handler ($46a-$47e) is directly called by the
	; Bios using the instruction 'JSR (A0)', A0 pointing to
	; the routine being invoked.
	; When the Bios returns to the caller, A0 still contains
	; the address of the invoked handler which is, in our
	; case, this dummy handler.
	; If the bootsector crashes and corrupts the memory
	; unexpectedly (by erroneously dereferencing A0), then
	; this program might be corrupted.
	; To avoid this, all scratch registers are set to zero
	; before returning to the Bios.
	; Although this precaution may seem unnecessary, the
	; problem depicted above actually happened!
hdv_ret	moveq.l	#0,d1
	move.l	d1,d2
	movea.l	d1,a0
	movea.l	d1,a1
	movea.l	d1,a2
	rts

	;
	; trap_enosys()
	;
	; Dummy handler for the AES/VDI vector (Trap #2).
	;
	; This handler is always installed in the AES/VDI
	; vector (Trap #2) because these services are not
	; available at boot time.
	;
trap_enosys:	
	moveq.l	#-32,d0         ; ENOSYS
	rte

	;
	; trap1_hook()
	;
	; GEMDOS (Trap #1) Hook.
	;
	; The GEMDOS vector is hooked in order to:
	;
	; - Completely disable the GEMDOS if the TOS variable that
	;   points to the current basepage could not be patched.
	;   The goal is to prevent the GEMDOS from crashing by
	;   making all GEMDOS calls inoperative.
	;   See FIX_CURR_BPAGE() for details.
	;
	; - Stop the execution of the bootsector if it calls
	;   a GEMDOS function that cannot be executed in the
	;   sandbox.
	;   Only the Character input/output and Time functions
	;   of the GEMDOS can be executed safely in the sandbox.
	;   Other functions (file, directory, memory or process)
	;   might fail or even crash when called in the sandbox.
	;   This is because it is not possible to set up a GEMDOS
	;   environment that is strictly identical to the one
	;   existing at boot time.
	;   But this is not really a problem since these functions
	;   are not supposed to be used if no filesystem is present
	;   on the disk (which should be the case of the floppy
	;   disk being examined).
	;   As a consequence, if such a function is called by the
	;   bootsector, it is considered an error and causes the
	;   execution to be stopped and control to be returned
	;   immediately to this program.
	;
trap1_hook:
	move.l	a0,-(a7)

	; Get the caller's stack pointer (User or Supervisor).
	lea	((4*1)+6)(a7),a0
	btst	#13,((4*1)+0)(a7)
	bne.s	.sup
	move.l	usp,a0
.sup
	; Functions with a number greater than Ptermres cannot be
	; executed in the sandbox.
	cmpi.w	#$31,(a0)       ; Ptermres
	bhs	exec_boot_err

	; If the TOS variable that points to the current basepage
	; could not be patched, do not invoke the GEMDOS.
	lea	tos_curr_basepage(pc),a0
	tst.l	(a0)
	bne.s	.jmp
	moveq.l	#-32,d0         ; ENOSYS
	movea.l	(a7)+,a0
	rte

	; Continue with the GEMDOS.
.jmp	movea.l	(a7)+,a0
trap1_jmp:
	jmp	$0.l

	;
	; trap7_hook()
	;
	; Trap exception triggered when the cracktro starts to
	; run, so that the cracktro is not executed and the
	; control is returned to this program.
	;
	; The code of the cracktro is modified on-the-fly by
	; the trap14_hook() routine that monitors the loading
	; of sectors.
	; Precisely, the instruction that is located at the
	; cracktro entry point is replaced with a "Trap #7"
	; so that the handler below is called when the cracktro
	; is executed.
	; This ensures that the control is returned to this
	; program when the loading of the cracktro is complete.
	; In fact, the entry point of the cracktro depends on
	; whether it is a raw binary or a GEMDOS PRG, i.e. it
	; can be at offset 0 or offset $1c respectively.
	; To be safe, the instruction located at each of the
	; two possible entry points is actually modified: the
	; instruction located at offset 0 is replaced with a
	; Trap #7 and the instruction located at offset $1c is
	; replaced with a Trap #8.
	; The handler below is thus called when the default entry
	; point is reached (located at offset 0 from the start
	; of the cracktro).
	;
	; See trap8_hook() and trap14_hook() below for more
	; details.
	;
	; The following handler is therefore installed in the
	; Trap #7 vector, which is a user-defined vector used
	; only by this program in order to detect the start of
	; the cracktro execution.
	;
trap7_hook:
	; Store in d0 the offset of the return address from the
	; start of the cracktro (i.e. the offset of the Trap #7
	; instruction + 2).
	moveq.l	#0+2,d0
	; Stop the "ripping" work.
	bra.s	rip_end

	;
	; trap8_hook()
	;
	; Trap exception triggered when the cracktro starts to
	; run, so that the cracktro is not executed and the
	; control is returned to this program.
	;
	; This handler is called when the cracktro is a GEMDOS PRG
	; and its entry point is reached (located at offset $1c
	; from the start of the cracktro).
	; To do so, the instruction located at this entry point
	; is replaced on-the-fly with a "Trap #8" by the
	; trap14_hook() routine.
	;
	; See trap7_hook() above and trap14_hook() below for
	; details.
	;
	; The following handler is therefore installed in the
	; Trap #8 vector, which is a user-defined vector used
	; only by this program in order to detect the start of
	; the cracktro execution.
	;
trap8_hook:
	; Store in d0 the offset of the return address from the
	; start of the cracktro (i.e. the offset of the Trap #8
	; instruction + 2).
	moveq.l	#$1c+2,d0
	; Fall-through to stop the "ripping" work.

	;
	; rip_end()
	;
	; Trap #7 and Trap #8 hooks jump here after the execution
	; of the cracktro has been intercepted and cancelled.
	;
	; - Check that the address where the cracktro is executed
	;   is the same as the address where it was loaded.
	;   If the two addresses are different, then this is
	;   considered an error.
	;   Indeed, undefined but necessary operations to the
	;   cracktro could have been performed between loading
	;   and execution.
	;
	; - If the cracktro is a PRG, verify that it has been
	;   fully loaded (i.e. the fixup table is complete).
	;
	; - Save the values of SR, SSP and USP when the cracktro
	;   is started, so that these registers can be set up
	;   similarly by the preamble code of the generated
	;   cracktro PRG.
	;
	; - Save the screen configuration set up by the boot
	;   sector before executing the cracktro.
	;   The same config will be set up by the preamble code
	;   of the generated cracktro PRG.
	;
	; In
	;   d0: offset of the executed Trap instruction + 2
	;   [a7]: Trap exception stack frame
	;
rip_end:
	; Debug only: save the value of SR when the cracktro
	; is started.
	ifne	DBG_BOOT_ANALYSIS
	lea	sr_start(pc),a0
	move.w	(a7),(a0)
	endc

	; Get the return address of the Trap exception.
	move.l	2(a7),d1
	; Get the start address of the cracktro by subtracting
	; the offset computed above from the return address.
	sub.l	d0,d1
	; Compare the execution address with the load address.
	; If the two addresses are different, then this is
	; considered an error.
	cmp.l	intro_load_addr(pc),d1
	bne	exec_boot_err

	; If the cracktro is a PRG, verify that it has been
	; fully loaded (i.e. the fixup table is complete).
	lea	intro_prg_size(pc),a0
	tst.l	(a0)
	beq.s	.regs
	tst.w	(intro_prg_valid-intro_prg_size)(a0)
	beq	exec_boot_err

	; Save the values of SR, SSP and USP, so that these
	; registers can be set up by the preamble code of the
	; generated cracktro PRG.
.regs	lea	intro_header_dest(pc),a0
	; Only the system byte of SR is saved.
	move.b	(a7),(intro_sr+2-intro_header)(a0)
	; SSP is saved only if it was modified by the bootsector.
	suba.l	a1,a1
	cmpa.l	#$80000,a7
	bhs.s	.ssp
	lea	6(a7),a1
.ssp	move.l	a1,(intro_ssp-intro_header)(a0)
	move	usp,a1
	move.l	a1,(intro_usp-intro_header)(a0)

	; Save the screen configuration so that it can be set up
	; by the preamble code of the generated cracktro PRG.
	bsr	save_screen_config

	; Destroy the sandbox and restore the original execution
	; environment.
	bra	exec_boot_end

	;
	; trap13_hook()
	;
	; Bios vector (Trap #13) hook.
	;
	; Implements the Bios disk operations (Getbpb, Mediach and
	; Rwabs) and in particular emulates the special behavior
	; they have at boot time.
	; These services are intended for use by the bootsector
	; when running in the sandbox.
	;
	; Getbpb, Mediach and Rwabs are emulated and not provided
	; as is to the bootsector, for the following 3 reasons:
	;
	; - Hard disk vectors have been rendered inoperative in
	;   case a resident hard disk driver has installed its
	;   own handlers (see the hdv_enosys() dummy handler).
	;   As a consequence, Bios disk operations are broken.
	;
	; - Bios disk operations have a special and unexpected
	;   behavior when used at boot time by the bootsector.
	;   But when the bootsector is run by this program in the
	;   sandbox, this special behavior is no longer in effect
	;   and must therefore be emulated.
	;   This special behavior consists in the Bios using a
	;   default BPB that does not match the current floppy
	;   disk: at boot time, whatever the actual format of
	;   the floppy disk, the Bios considers that it has the
	;   following arbitrary format: 1 side, 9 sectors per
	;   track and 80 tracks.
	;   This behavior is in effect until a call to the Getbpb
	;   function is made, at which point the Bios uses the
	;   BPB of the current floppy disk.
	;   As a result, when the bootsector calls the Rwabs
	;   function at boot time to read logical sectors, the
	;   true format of the floppy disk is ignored and the
	;   arbitrary format of the default BPB is used instead.
	;   Note that this feature was used in the loader of the
	;   game "Around the world", loader coded by Mike Mee
	;   also known as "Mug UK".
	;
	; - Emulating the Rwabs function of the Bios can be done
	;   using the Floprd function of the XBios, which allows
	;   to have only one place (Floprd) where disk accesses
	;   need to be monitored in order to detect the loading
	;   of the cracktro.
	;
trap13_hook:
	movem.l	d0-d1/a0-a1,-(a7)

	; Get the caller's stack pointer (User or Supervisor).
	lea	((4*4)+6)(a7),a0
	btst	#13,((4*4)+0)(a7)
	bne.s	.sup
	move.l	usp,a0
.sup
	;
	; Emulate Getbpb() for the drive A only.
	;
.getbpb	cmpi.w	#7,(a0)         ; Getbpb
	bne.s	.dchg
	tst.w	2(a0)           ; DRV A
	bne.s	.cont

	; Replace the cached FAT12 BPB with the one fetched from
	; the current floppy disk.
	; The cached FAT12 BPB initially contains the following
	; values: 1 side, 9 sectors per track, 80 tracks.
	; This corresponds to the default BPB that is used by the
	; Bios at boot time (see the explanation in the function
	; description above).
	lea	bootsector_buf(pc),a0
	lea	boot_bpb(pc),a1
	moveq.l	#BPB_SIZE/2-1,d0
.cp_bpb	move.w	(a0)+,(a1)+
	dbf	d0,.cp_bpb

	; Convert the cached FAT12-style BPB into a Bios-style
	; BPB that can be returned to the caller.
	lea	boot_bpb(pc),a0
	lea	bios_bpb(pc),a1
	bsr	boot2bios_bpb
	; d0 contains the address of the Bios BPB that is
	; returned to the caller.
	bra.s	.done

	;
	; Emulate Mediach() for the drive A only.
	;
.dchg	cmpi.w	#9,(a0)         ; Mediach
	bne.s	.rwabs
	tst.w	2(a0)           ; DRV A
	bne.s	.cont

	; 0: media definitely has not changed.
	moveq.l	#0,d0
	bra.s	.done

	;
	; Emulate Rwabs() for the drive A only.
	;
.rwabs	cmpi.w	#4,(a0)         ; Rwabs
	bne.s	.cont
	tst.w	12(a0)          ; DRV A
	bne.s	.cont
	btst.b	#0,3(a0)        ; Read
	bne.s	.cont

	; Debug only: indicate that Rwabs has been used.
	ifne	DBG_BOOT_ANALYSIS
	lea	use_rwabs(pc),a1
	st	(a1)
	endc

	move.w	10(a0),d0       ; Logical starting sector
	move.w	8(a0),d1        ; Nb of sectors to read
	movea.l	4(a0),a0        ; Receiving buffer
	lea	boot_bpb(pc),a1 ; Cached FAT12 BPB

	; The sector_read() function uses the Floprd call
	; of the XBios to mimic the Rwabs call of the Bios.
	bsr	sector_read

	; Bios disk operation emulated, return to the caller.
.done	addq.l	#4,a7
	movem.l	(a7)+,d1/a0-a1
	rte

	; Operation not emulated, continue with the Bios.
.cont	movem.l	(a7)+,d0-d1/a0-a1
trap13_jmp:
	jmp	$0.l

	;
	; trap14_hook()
	;
	; XBios vector (Trap #14) hook.
	;
	; Hooks the Floprd function of the XBios and monitors
	; disk accesses in order to detect the loading of the
	; cracktro.
	;
	; This routine actually does only a few checks because
	; it delegates disk access monitoring to the trap14_post()
	; routine which is executed when the Floprd call returns.
	;
	; Only the Floprd call needs to be hooked because any
	; sector loading is achieved by this function, Rwabs
	; being emulated on top of Floprd. See trap13_hook().
	;
trap14_hook:
	movem.l	d0-d1/a0-a1,-(a7)

	; Get the caller's stack pointer (User or Supervisor).
	lea	((4*4)+6)(a7),a0
	btst	#13,((4*4)+0)(a7)
	bne.s	.sup
	move.l	usp,a0
.sup
	; Hook the Floprd function.
	;
	; In the sandbox, all sectors read by Floprd are read
	; from floppy drive A whatever the device specified in
	; the parameters of the function.
	; This is because the _nflops variable has been forced
	; to 1 and the floppy disk switching mechanism has been
	; disabled (by installing a dummy GEM critical error
	; handler).
	; So, all requests are intercepted regardless of the
	; specified device and treated as made on drive A.
	cmpi.w	#8,(a0)         ; Floprd
	bne.s	.ret

	; Debug only: save the value of SR when the cracktro
	; is loaded. Save also the value of the Trace vector.
	ifne	DBG_BOOT_ANALYSIS

	lea	sr_load(pc),a1
	tst.w	(a1)
	bne.s	.dbg_ct
	move.w	((4*4)+0)(a7),(a1)
	move.l	$24.w,(trace_load-sr_load)(a1)
.dbg_ct
	endc

	moveq.l	#0,d0
	move.w	18(a0),d0       ; Nb of sectors to read
	moveq.l	#9,d1           ; 512 = 1<<9
	lsl.l	d1,d0           ; Size to read

	; Check that the sectors are loaded contiguously in memory,
	; i.e. that the transfer buffers passed successively to the
	; Floprd function are contiguous.
	; If the sectors are not loaded contiguously, this implies
	; that there is no self-contained binary of the cracktro,
	; and therefore ripping is not possible.
	lea	trap14_buf_next(pc),a1
	move.l	(a1),d1         ; Expected buffer address
	bne.s	.chksrc         ;  (= end of prev buffer)
	move.l	2(a0),d1        ; Special case of 1st call
.chksrc	cmp.l	2(a0),d1        ; Caller's buffer address
	bne	exec_boot_err   ; Error if caller's buffers
		                ;  are not contiguous

	; Check that all sectors are loaded above the system
	; variables and especially the system crash page where
	; the trampoline of the preamble code is executed.
	cmpi.l	#$5c0,d1        ; Upper limit of system vars
	blo	exec_boot_err

	; Check that all sectors are loaded in low memory,
	; i.e. below $80000, so that this program that has been
	; relocated above $80000 is not corrupted.
	add.l	d0,d1           ; End of caller's buffer
	cmpi.l	#$80000,d1      ;  must be in low memory,
	bhi	exec_boot_err   ;  if not, raise an error

	; Save the end address of the caller's buffer as the
	; expected buffer address for the next sector read
	; (transfer buffers must be contiguous).
	move.l	d1,(a1)

	; Check that the size of the data already read (including
	; the new transfer) does not exceed the size of the buffer
	; allocated for saving the cracktro.
	add.l	intro_buf_next(pc),d0
	move.l	intro_buf_rel(pc),d1
	addi.l	#INTRO_BUF_SIZE,d1
	cmp.l	d1,d0
	bhi	exec_boot_err

	; The detection of the loading of the cracktro is performed
	; by the trap14_post() routine that is executed upon return
	; of the Floprd call.
	; Modify the stack frame so that the XBios returns to the
	; trap14_post() routine. Also save the caller's return
	; address so that trap14_post() can return to the caller.
	lea	trap14_ret(pc),a0
	move.l	((4*4)+2)(a7),2(a0)
	lea	trap14_post(pc),a0
	move.l	a0,((4*4)+2)(a7)

.ret	movem.l	(a7)+,d0-d1/a0-a1
trap14_jmp:
	jmp	$0.l

	;
	; trap14_post()
	;
	; XBios vector (Trap #14) post hook.
	;
	; Monitors the sectors loaded by the Floprd function
	; of the XBios in order to:
	;
	; - Detect the loading of the cracktro and in particular
	;   determine the type of the cracktro binary (raw binary
	;   or GEMDOS PRG), the size of the cracktro and the
	;   address where the cracktro is loaded (which must be
	;   the same address where it is executed).
	;
	; - Save the cracktro into a safe memory area.
	;
	; - Stop the execution of the bootsector once the cracktro
	;   has been fully loaded and saved.
	;   To this end, the instruction of the cracktro entry
	;   point is modified on-the-fly so that the execution
	;   of the cracktro triggers a trap exception.
	;   This allows to intercept the cracktro execution and
	;   return to this program.
	;
	; The trap14_hook() routine above ensures that
	; trap14_post() is executed when the Floprd call is about
	; to return from the XBios.
	; trap14_post() inspects the sectors that have just been
	; loaded, takes appropriate action and then returns to the
	; actual caller of Floprd (typically the bootsector running
	; in the sandbox).
	;
	; The cracktro can be loaded from arbitrary sectors but
	; it must be loaded as a contiguous block of memory in
	; order to be ripped and saved as a self-contained binary.
	;
trap14_post:
	; If Floprd failed, return to the caller now.
	tst.l	d0
	bne	trap14_ret

	movem.l	d0-d1/a0-a3,-(a7)

	; Kick the timer-C-based and VBL-based watchdog timers.
	; See the timerc_hook() and vbl_hook() routines for the
	; implementation of these watchdog timers.
	lea	timecounters(pc),a0
	move.l	(a0),(timestamps-timecounters)(a0)

	; The cracktro is saved to a safe memory area on-the-fly
	; during sector loading.
	; Here, the content of the sectors that have just been
	; read is saved.
	movea.l	((4*6)+2)(a7),a0   ; Caller's buffer
	movea.l	intro_buf_next(pc),a1
	movea.l	a0,a2
	move.w	((4*6)+18)(a7),d0  ; Nb of sectors
	lsl.w	#(9-3),d0
	subq.w	#1,d0              ; Size of the read data

.cp	move.l	(a0)+,(a1)+
	move.l	(a0)+,(a1)+
	dbf	d0,.cp

	movea.l	a0,a3              ; End of caller's buffer

	; Update the address from which the following sectors
	; will be saved the next time Floprd is called.
	lea	intro_buf_next(pc),a0
	move.l	a1,(a0)

	; Is this the first call to Floprd?
	; i.e. the very first sectors of the cracktro have just
	; been loaded?
	lea	intro_prg_size(pc),a0
	lea	intro_load_addr(pc),a1
	tst.l	(a1)
	bne.s	.endprg

	; If yes, save the loading start address.
	; This address is both the loading and the execution
	; address of the cracktro.
	move.l	a2,(a1)

	; And check if custom processing is needed.
	bsr	custom_fixes

	; Also patch the two possible cracktro entry points to
	; intercept the execution of the cracktro and stop the
	; "ripping" work.
	; The first instruction (the default entry point) is
	; replaced with a "Trap #7" and the instruction located
	; at offset $1c (the entry point of a GEMDOS PRG) is
	; replaced with a "Trap #8"
	; See also trap7_hook() and trap8_hook().
	move.w	(a2),d0            ; Save PRG magic
	move.w	#$4e47,(a2)        ; Trap #7 at offset 0
	move.w	#$4e48,$1c(a2)     ; Trap #8 at offset $1c

	; Finally determine the type of the cracktro binary,
	; i.e. is the cracktro a raw binary or a GEMDOS PRG?
	cmpi.w	#$601a,d0          ; Valid PRG magic?
	bne.s	.noprg
	tst.l	18(a2)             ; Reserved, should be 0
	bne.s	.noprg
	moveq.l	#$1c+4,d0
	add.l	2(a2),d0           ; Text size
	add.l	6(a2),d0           ; Data size
	add.l	14(a2),d0          ; Symbol table size
	cmpi.l	#INTRO_BUF_SIZE,d0 ; Valid size?
	bhi.s	.noprg             ;  no, it isn't a PRG

	; Assume the cracktro binary is a GEMDOS PRG.
	;
	; Save the size calculated from the PRG header information.
	; This size does not include the relocation/fixup table.
	; The total size of the PRG (including the fixup table)
	; is determined on-the-fly when the last sectors of the
	; cracktro binary are loaded.
	; See .endprg below.
	move.l	d0,(a0)            ; Save the PRG size
	; Fall-through.

	; If the cracktro is a GEMDOS PRG, perform additional
	; checks and especially determine the exact size of the
	; PRG and verify that it is complete.
.endprg	move.l	(a0),d0            ; Is the cracktro a PRG?
	beq.s	.ret               ; If not, return

	; If the GEMDOS PRG has already been fully loaded,
	; then just ignore these extra sectors.
	tst.w	(intro_prg_valid-intro_prg_size)(a0)
	bne.s	.ret

	; Otherwise, check if the GEMDOS PRG is complete.
	; First, has the PRG size calculated at the beginning of
	; sector loading been reached?
	movea.l	(a1),a2            ; Loading start address
	move.l	a3,d1              ; End of caller's buffer
	sub.l	a2,d1              ; Size of all data read
	cmp.l	d0,d1              ; PRG size reached?
	blo.s	.ret               ; If not, return

	; Yes, check if the relocation/fixup table is present,
	; valid and complete. This table was not taken into
	; account when estimating the PRG size at the start
	; of sector loading.

	; Check if the fixup table is present.
	movea.l	a2,a1              ; Start addr of the PRG
	adda.l	d0,a1              ; End addr of the PRG
	move.l	-4(a1),d1          ; Reloc table present?
	beq.s	.prgok             ; If not, all done

	; Check if the fixup table is valid.
	; Only check the first fixup longword.
	btst	#0,d1              ; Even fixup?
	bne.s	.noprg             ;  no, fixup is invalid
	cmp.l	d0,d1              ; Fixup >= PRG size?
	bhs.s	.noprg             ;  yes, fixup is invalid
	add.l	10(a2),d0          ; Add BSS to PRG size
	move.l	$1c(a2,d1.l),d1    ; Entry to be relocated
	cmp.l	d0,d1              ;  > total PRG size?
	bhi.s	.noprg             ;  yes, fixup is invalid

	; Check if the fixup table is complete.
	; Search for the zero that terminates the fixup table.
	; If it is not found in the data already loaded, then
	; the fixup table is incomplete and the loading is not
	; finished.
.fixup	cmpa.l	a3,a1              ; If no more data, the
	bhs.s	.ret               ;  table is incomplete
	tst.b	(a1)+              ; Search for the
	bne.s	.fixup             ;  terminating zero

	; Update the size of the PRG so that it now includes
	; the fixup table.
.prgok	suba.l	a2,a1
	move.l	a1,(a0)            ; Update the PRG size

	; Indicate that the cracktro PRG has been fully loaded.
	st.b	(intro_prg_valid-intro_prg_size)(a0)

	; Return to the caller and wait for the Trap #7 or Trap #8
	; hook to be triggered.
	bra.s	.ret

	; If the cracktro is a raw binary, just clear the PRG size
	; and wait for the cracktro execution to be intercepted.
.noprg	clr.l	(a0)               ; Clear the PRG size

	; Return to the caller of Floprd.
.ret	movem.l	(a7)+,d0-d1/a0-a3
trap14_ret:
	jmp	$0.l

	;
	; hook_illegal_tvd()
	;
	; Hook the TVD handler used in Illegal's protection.
	;
	; The following hook is executed right before Illegal's
	; TVD handler, each time an encrypted instruction of the
	; bootsector is executed. The purpose of this hook is to
	; monitor the execution of the bootsector's encrypted code
	; and modify its behavior if necessary, in particular to
	; disable the cracktro checksum.
	;
hook_illegal_tvd:
	move.l	a0,-(a7)

	; Here is Illegal's decrypted checksum routine:
	;
	; 2c4d                movea.l   a5,a6
	; 3e3c 1659           move.w    #SIZE,d7
	; 7000                moveq.l   #0,d0
	; d01e        Loop    add.b     (a6)+,d0
	; bf00                eor.b     d7,d0
	; d0b8 0010           add.l     $0010.w,d0
	; 51cf fff6           dbra      d7,Loop
	; b03c 0079           cmpi.b    #CSUM,d0
	; 6611                bne.s     Error
	; 46fc 2300           move      #$2300,sr
	; 4ed5                jmp       (a5)

	; Determine which encrypted instruction was executed last.
	movea.l	hook_illegal_tvd_jmp+2(pc),a0
	movea.l	40(a0),a0         ; Latest decoded instr
.cmp	cmpi.w	#$b03c,(a0)       ; cmpi.b #CSUM,d0
	bne.s	.eor
	; Ensures that the checksum is considered valid.
	move.b	#$04,5(a7)        ; sr[Z]=1
	bra.s	.ret
.eor	cmpi.w	#$bf00,(a0)       ; eor.b d7,d0
	bne.s	.ret
	; Shortens the checksum calculation to speed up execution.
	moveq.l	#0,d7             ; Loop iteration counter

.ret	movea.l	(a7)+,a0

	; Execute the original TVD handler.
hook_illegal_tvd_jmp:
	jmp	$0.l

	;
	; disable_illegal_tvd()
	;
	; Disable Illegal's TVD-based protection.
	;
	; Most of Illegal's bootloaders are using a TVD-based
	; protection and a checksum to prevent the boot-cracktro
	; from being modified.
	; This protection is disabled here, so that the cracktro
	; can be patched on-the-fly by this program to intercept
	; and stop its execution.
	;
	; Scratch: d0/a0
	;
disable_illegal_tvd:
	; First, determine if Illegal's protection is present.
	move.l	$24.w,d0          ; Trace vector
	beq.s	.ret
	movea.l	$4c6.w,a0         ; Start of bootsector
	cmp.l	a0,d0
	bls.s	.ret
	lea	$200(a0),a0       ; End of bootsector
	cmp.l	a0,d0             ; Is the Trace handler
	bhs.s	.ret              ;  in the bootsector?
	btst	#0,d0             ; Even handler address?
	bne.s	.ret              ; Yes, check the content
	movea.l	d0,a0             ;  of the Trace handler
	cmpi.l	#$206f003e,4(a0)  ; movea.l $3e(a7),a0
	bne.s	.ret
	cmpi.l	#$43fa001e,8(a0)  ; lea addr(pc),a1
	bne.s	.ret
	cmpi.l	#$2028fff4,18(a0) ; move.l $fff4(a0),d0
	bne.s	.ret
	cmpi.l	#$46804840,22(a0) ; not.l d0 ; swap d0
	bne.s	.ret
	cmpi.l	#$b1904cdf,32(a0) ; eor.l d0,(a0) ; movem.l
	bne.s	.ret

	; Illegal's TVD-based protection has been identified.
	; Hook the Trace handler of the protection to modify
	; the behavior of the encrypted code on-the-fly.
	; See hook_illegal_tvd() above for details.
	lea	hook_illegal_tvd(pc),a0
	move.l	$24.w,(hook_illegal_tvd_jmp+2-hook_illegal_tvd)(a0)
	move.l	a0,$24.w

	; Debug only: indicate that Illegal's prot has been
	; identified.
	ifne	DBG_BOOT_ANALYSIS
	lea	prot_type(pc),a0
	move.w	#PROT_ILLEGAL_TVD,(a0)
	endc	; DBG_BOOT_ANALYSIS
.ret	rts

	;
	; disable_illegal_clear()
	;
	; Disable Illegal's second protection, which is a
	; simple (not encrypted) checksum routine executed
	; in the bootsector before running the boot-cracktro.
	;
	; This second protection is a simplified version of
	; the TVD based protection. The checksum routine is
	; similar but there is no TVD, the checksum routine
	; is in "plain text".
	;
	; The checksum is disabled here, so that the cracktro
	; can be patched on-the-fly and its execution intercepted.
	;
	; Scratch: d0/a0
	;
disable_illegal_clear:

	; Here is Illegal's simple checksum routine:
	;
	; 2c4d                movea.l   a5,a6
	; 3e3c 55ef           move.w    #SIZE,d7
	; 7000                moveq.l   #0,d0
	; d01e        Loop    add.b     (a6)+,d0
	; 51cf fffc           dbra      d7,Loop
	; b03c 00b9           cmpi.b    #CSUM,d0
	; 6611                bne.s     Error
	; 4ed5                jmp       (a5)

	; Determine if the protection is there.
	movea.l	$4c6.w,a0         ; Start of bootsector
	move.w	#512/2-10,d0      ; Nb of words to scan

.scan	cmpi.w	#$2c4d,(a0)+      ; movea.l   a5,a6
	dbeq	d0,.scan
	bne.s	.end              ; If not found, stop
	cmpi.w	#$3e3c,(a0)       ; move.w    #SIZE,d7
	bne.s	.scan
	cmpi.w	#$7000,4(a0)      ; moveq.l   #0,d0
	bne.s	.scan
	cmpi.w	#$d01e,6(a0)      ; add.b     (a6)+,d0
	bne.s	.scan
	cmpi.w	#$b03c,12(a0)     ; cmpi.b    #CSUM,d0
	bne.s	.scan
	cmpi.b	#$66,16(a0)       ; bne.s     Error
	bne.s	.scan
	cmpi.w	#$4ed5,18(a0)     ; jmp       (a5)
	bne.s	.scan

	; The protection is present, patch it to skip the
	; checksum part.
	move.w	#$4ed5,-(a0)      ; jmp       (a5)

	; Debug only: indicate that Illegal's second protection
	; has been identified.
	ifne	DBG_BOOT_ANALYSIS
	lea	prot_type(pc),a0
	move.w	#PROT_ILLEGAL_CLEAR,(a0)
	endc	; DBG_BOOT_ANALYSIS

.end	rts

	;
	; custom_fixes()
	;
	; Check if custom processing is needed.
	;
	; This ranges from disabling a specific protection to
	; supporting a particular unpacking method...
	;
	; For example, most of Illegal's boot-cracktros are
	; protected against hacking: a simple Trace-Vector-Decoder
	; is used in the bootsector to hide the loading of the
	; cracktro, then the checksum of the cracktro is verified
	; to ensure its integrity.
	; Obviously, the checksum prevents this program from
	; patching the cracktro on-the-fly to intercept and stop
	; its execution, which means that Illegal's protection
	; must be disabled.
	;
custom_fixes:
	movem.l	d0-d1/a0-a1,-(a7)

	; Disable Illegal's TVD-based protection.
	bsr	disable_illegal_tvd

	; Disable Illegal's second protection, which is a
	; simple (not encrypted) checksum routine.
	bsr.s	disable_illegal_clear

	; More custom processing can be added here.

	movem.l	(a7)+,d0-d1/a0-a1
	rts

	;
	; exec_boot()
	;
	; Execute the bootsector in a sandbox and rip the
	; boot-cracktro.
	;
	; Precisely, this routine does the following:
	; - Create a special execution environment, called a
	;   sandbox, that allows the bootsector to be safely
	;   executed in low user memory as if it were running
	;   at boot time.
	; - Hook the Bios vector to "emulate" Bios disk operations
	;   (Getbpb, Mediach and Rwabs) on top of the Floprd call
	;   of the XBios.
	; - Hook the XBios vector to monitor disk access in order
	;   to detect the loading of the boot-cracktro and save it
	;   on-the-fly.
	; - Hook the timer C and VBL vectors to provide 2 watchdog
	;   timers that trigger a time out error if no disk access
	;   is detected within a defined period of time.
	; - Execute the routine passed in parameter: this allows
	;   to execute either the bootsector or a self-test in the
	;   sandbox.
	; - Stop the execution of the routine passed in parameter
	;   once the boot-cracktro has been ripped or an error has
	;   occurred.
	; - Restore the execution environment (destroy the
	;   sandbox).
	; - Return an error code indicating whether the cracktro
	;   was successfully ripped.
	;
	; Called from supexec.
	;
	; In:
	;   a1: address of the routine executed by exec_boot()
	;       once the "ripping" environment has been set up;
	;       this allows to execute either the bootsector or
	;       a selftest in the sandbox
	;
	; Out:
	;   d0: 0 if the cracktro was successfully ripped,
	;       a negative value otherwise
	;
exec_boot:
	; Push USP onto the stack.
	move	usp,a0
	move.l	a0,-(a7)

	; Save SP.
	lea	ssp_saved(pc),a0
	move.l	a7,(a0)

	; Reset variables that could have been modified in
	; the previous run.
	lea	intro_prg_size(pc),a0  ; GEMDOS PRG size
	clr.l	(a0)
	lea	intro_prg_valid(pc),a0 ; Valid ripped PRG?
	clr.w	(a0)
	lea	intro_load_addr(pc),a0 ; Load/exec address
	clr.l	(a0)
	lea	intro_load_err(pc),a0  ; Rip error
	clr.l	(a0)
	lea	intro_buf_next(pc),a0  ; Buffer to save
	move.l	intro_buf_rel(pc),(a0) ;  the cracktro
	lea	trap14_buf_next(pc),a0 ; Buffer of the
	clr.l	(a0)                   ;  Floprd caller
	lea	timecounters(pc),a0    ; Watchdog counters
	clr.l	(a0)                   ;  and timestamps
	clr.l	(timestamps-timecounters)(a0)

	; And reset also debug-only variables.
	ifne	DBG_BOOT_ANALYSIS
	lea	use_rwabs(pc),a0
	clr.w	(a0)
	clr.w	(sr_load-use_rwabs)(a0)
	clr.w	(sr_start-use_rwabs)(a0)
	clr.l	(trace_load-use_rwabs)(a0)
	move.w	#PROT_NONE,(prot_type-use_rwabs)(a0)
	endc

	; Reset the cached FAT12 BPB to the initial values.
	move.w	#(boot_bpb_initial_end-boot_bpb_initial)/2-1,d0
	lea	boot_bpb_initial(pc),a0
	lea	boot_bpb(pc),a2
.cp_bpb	move.w	(a0)+,(a2)+
	dbf	d0,.cp_bpb

	; Set up the sandbox.
	bsr	setup_lowmem

	; Install the timer-C-based watchdog timer.
	lea	timerc_hook(pc),a0
	move.l	$114.w,(timerc_jmp+2-timerc_hook)(a0)
	move.l	a0,$114.w

	; Install the VBL-based watchdog timer.
	lea	vbl_hook(pc),a0
	move.l	$70.w,(vbl_jmp+2-vbl_hook)(a0)
	move.l	a0,$70.w

	; Install the first Trap handler (Trap #7) used to
	; intercept the execution of the cracktro.
	lea	trap7_hook(pc),a0
	move.l	a0,$9c.w

	; Install the second Trap handler (Trap #8) used to
	; intercept the execution of the cracktro.
	lea	trap8_hook(pc),a0
	move.l	a0,$a0.w

	; Install the Bios vector hook used to emulate Bios
	; disk operations.
	lea	trap13_hook(pc),a0
	move.l	$b4.w,(trap13_jmp+2-trap13_hook)(a0)
	move.l	a0,$b4.w

	; Install the XBios vector hook used to monitor disk
	; access and rip the cracktro.
	lea	trap14_hook(pc),a0
	move.l	$b8.w,(trap14_jmp+2-trap14_hook)(a0)
	move.l	a0,$b8.w

	; Kick the watchdog timers.
	lea	timecounters(pc),a0
	move.l	(a0),(timestamps-timecounters)(a0)

	;
	; Set up proper register values.
	;

	lea	$80000-8,a0
	move	a0,usp
	lea	$80000+STACK_SIZE,a7
	movea.l	a1,a0

	moveq.l	#0,d0
	move.l	d0,d1
	move.l	d0,d2
	move.l	d0,d3
	move.l	d0,d4
	move.l	d0,d5
	move.l	d0,d6
	move.l	d0,d7
	movea.l	d0,a1
	movea.l	d0,a2
	movea.l	d0,a3
	movea.l	d0,a4
	movea.l	d0,a5
	movea.l	d0,a6

	; Execute the routine passed in parameter.
	; It can be either bootsector_trampoline() or a selftest.
	jsr	(a0)

	; Special case where something has been loaded by the
	; bootsector but control is returned here, indicating
	; that no cracktro has been ripped.
	; This can happen if the bootsector loads data without
	; executing it, e.g. it loads an image, displays it and
	; then returns to the TOS.
	; This case is considered an error.
	move.l	intro_load_addr(pc),d0
	bne.s	exec_boot_err

	; The "ripping" work is finished, destroy the sandbox.
exec_boot_end:
	; Restore SP.
	movea.l	ssp_saved(pc),a7

	; Restore the execution environment that had been saved
	; by the setup_lowmem() routine.
	bsr	restore_lowmem

	; Restore USP.
	movea.l	(a7)+,a0
	move	a0,usp

	; Return an error code indicating whether the cracktro
	; was successfully ripped.
	move.l	intro_load_err(pc),d0
	rts

	;
	; exec_boot_err()
	;
	; The hooks jump here when an error occurs during the
	; "ripping" work.
	;
	; - The execution of the bootsector is interrupted
	;   immediately.
	; - An error code is set.
	; - Control is returned to the exec_boot() routine
	;   above to restore a clean execution environment.
	;
exec_boot_err:
	move.w	#$2700,sr
	lea	intro_load_err(pc),a0
	subq.l	#1,(a0)         ; Error = -1
	bra.s	exec_boot_end

	;
	; save_screen_config()
	;
	; Save the screen configuration defined by the bootsector
	; before executing the cracktro.
	;
	; Some bootloaders set up the screen directly in the
	; bootsector before loading and executing the cracktro,
	; and the boot-cracktro uses that screen configuration
	; "as is".
	;
	; Such configuration (screen resolution, address and
	; palette) is dumped here so that it can be set up by
	; the preamble code when running the cracktro from the
	; GEM. See intro_preamble().
	;
save_screen_config:
	movem.l	d0-d2/a0-a2,-(a7)

	lea	intro_header_dest(pc),a0

	; Resolution.
	move.b	$ffff8260.w,d0
	andi.w	#3,d0           ; Cut "floating" bits on ST
	move.w	d0,(intro_rez-intro_header)(a0)

	; Video address.
	move.b	$ffff8201.w,(intro_vbase-intro_header+1)(a0)
	move.b	$ffff8203.w,(intro_vbase-intro_header+2)(a0)

	; Palette.
	lea	$ffff8240.w,a1
	lea	(intro_pal-intro_header)(a0),a2
	moveq.l	#15,d0
.col	move.w	(a1)+,d1
	andi.w	#$0777,d1       ; Cut "floating" bits on ST
.red	move.w	d1,d2
	andi.w	#$0700,d2
	cmpi.w	#$0700,d2       ; ST R0-R2?
	bne.s	.green
	ori.w	#$0800,d1       ; STe R0
.green	move.w	d1,d2
	andi.w	#$0070,d2
	cmpi.w	#$0070,d2       ; ST G0-G2?
	bne.s	.blue
	ori.w	#$0080,d1       ; STe G0
.blue	move.w	d1,d2
	andi.w	#$0007,d2
	cmpi.w	#$0007,d2       ; ST B0-B2?
	bne.s	.save
	ori.w	#$0008,d1       ; STe B0
.save	move.w	d1,(a2)+
	dbf	d0,.col

	movem.l	(a7)+,d0-d2/a0-a2
	rts

	;
	; Cracktro preamble.
	;
	; The ripped cracktro is wrapped in a special code, called
	; preamble, whose purpose is to make the cracktro runnable
	; from the GEM. The resulting program is saved as a regular
	; GEMDOS PRG file.
	;
	; The preamble installs and runs the cracktro at the same
	; address used by the original bootsector.
	;
	; An execution context as close as possible to the one
	; existing at boot-time is set up. It allows the cracktro
	; to run in low user memory and possibly trash the memory
	; used by the GEM without consequences (the GEM allocates
	; the first 32 KB of low user memory, starting at _membot).
	;
	; To this end, several services set up by the GEM after
	; boot are disabled in order to return to a runtime
	; environment similar to the one at boot. This is the
	; same process used by the setup_lowmem() routine to
	; create the sandbox.
	;
	; The video controller (resolution, address, palette)
	; is also set up as it was originally configured by the
	; bootsector before executing the boot-cracktro.
	;
intro_header:
	;
	; GEMDOS PRG header.
	;
	bra.s	intro_preamble  ; $601a
	ds.b	$1a
intro_preamble:
	;
	; Self-promotion! 
	;
	bra	.start
	dc.b	" >>> Cracktro ripped using the BOOT-CRACKTRO "
	dc.b	"R1PP3R v1.0 from Orion of The Replicants. "
	dc.b	"Source code available at: "
	dc.b	"https://github.com/orionfuzion <<< ",0
	even

	;
	; Start of the preamble code.
	;
.start	
	; Save the program basepage in a6.
	movea.l	4(a7),a6

	; Switch to supervisor mode, which is the execution mode
	; at boot-time.
	clr.l	-(a7)
	move.w	#$20,-(a7)
	trap	#1

	; Use the initial (boot-time) SSP.
	movea.l	d0,a7

	; Vsync.
	move.w	#$25,-(a7)
	trap	#14
	addq.l	#2,a7

	; All palette colors are set to the value of the
	; background color as defined by the bootsector
	; before executing the boot-cracktro.
	lea	$ffff8240.w,a0
	move.w	intro_pal(pc),d0
	move.w	#15,d1
.col	move.w	d0,(a0)+
	dbf	d1,.col

	; Hide the mouse pointer.
	dc.w	$a00a

	; Disable key auto-repeat.
	bclr.b	#1,$484.w

	; Clear the screen.
	pea	.cls(pc)
	move.w	#9,-(a7)
	trap	#1
	addq.l	#6,a7

	; Some vectors are hooked or set up with custom handlers.
	; Copy these resident handlers in the system crash page
	; as well as the trampoline code that will install and
	; launch the cracktro. The system crash page is located
	; at the very beginning of the low memory, between $380
	; and $400.
	lea	.resid_start(pc),a0
	lea	TRAMP_DEST.w,a1
	move.w	#(.resid_end-.resid_start)/2-1,d0
.cp	move.w	(a0)+,(a1)+
	dbf	d0,.cp

	; Try to find handlers in ROM that are identical to the
	; custom handlers previously copied in the system crash
	; page. Using handlers in ROM allows to defeat protections
	; that check the contents of the vectors (like Anti-bitos
	; or Cooper). If such ROM handlers cannot be found, the
	; custom handlers copied in the system crash page are
	; used instead.
	;
	; There are 3 different custom handlers:
	; 1. A dummy exception handler which just returns.
	; 2. The .trap_err exception handler which returns -1.
	; 3. The .hdv_err subroutine which returns -1.
	;
	; At the end of this routine, the addresses of the 3
	; handlers are stored in the following registers:
	; a3: dummy exception handler in ROM.
	; a4: .trap_err exception handler in the system crash
	;     page or equivalent in ROM.
	; a5: .hdv_err subroutine in the system crash page or
	;     equivalent in ROM.
	lea	TRAP_ERR_DEST.w,a4
	lea	HDV_ERR_DEST.w,a5
	movea.l	$4f2.w,a0     ; OSHEADER (SYSHDR)
	movea.l	8(a0),a0      ; Real OS base address
	moveq.l	#-1,d0        ; Scan 128KB
	move.w	#$4e73,d1     ; rte
	move.w	#$4e75,d2     ; rts
	moveq.l	#0,d3         ; Bitfield of found handlers
.romlp	move.w	(a0)+,d4      ; Next word in ROM
	cmp.w	d4,d1         ; rte?
	beq.s	.romrte       ;  yes, check the prev instr
	cmp.w	d4,d2         ; rts?
	dbeq	d0,.romlp     ;  if not, scan again
	bne.s	.romend       ; 128KB scanned, stop
.romrts	cmpi.w	#$70ff,-4(a0) ; moveq #-1,d0?
	bne.s	.romlp        ;  if not, scan again
	lea	-4(a0),a5     ; Start of 3rd handler
	ori.b	#%100,d3      ; 3rd handler found
	bra.s	.romchk       ; Check if all handlers found
.romrte	lea	-2(a0),a3     ; Start of 1st handler
	ori.b	#%001,d3      ; 1st handler found
	move.w	-4(a0),d4     ; Previous instruction
	andi.w	#$fff0,d4
	cmpi.w	#$70f0,d4     ; moveq #-x,d0?
	bne.s	.romlp        ;  if not, scan again
	lea	-4(a0),a4     ; Start of 2nd handler
	ori.b	#%010,d3      ; 2nd handler found
.romchk	cmpi.b	#%111,d3      ; All handlers found?
	bne.s	.romlp        ;  if not, scan again
.romend
	; Modify the CPU exception vectors so that the "fatal"
	; routine copied in the system crash page is called
	; in case of a CPU exception.
	lea	$8.w,a0
	moveq.l	#7,d0
.s_err	move.l	#FATAL_DEST,(a0)+
	dbf	d0,.s_err

	; Ignore "Zero Divide" exceptions.
	move.l	a3,$14.w

	; Some boot-cracktros use the Line-A even though it is not
	; initialized at boot time. The trivial solution to avoid
	; any problem with the Line-A (which behaves differently
	; when the cracktro is run from the GEM) would be to simply
	; disable it. But this is not feasible because finding a
	; suitable dummy handler in ROM is not possible. Indeed
	; the return address of the exception must be fixed and
	; therefore a simple RTE instruction is not enough.
	; But this is not a problem because the Line-A is usually
	; only used to hide the mouse and since the mouse is
	; already hidden by the preamble code, such a request
	; from the cracktro will have no effect and the TOS will
	; simply return. So the risk that the Line-A could have
	; a negative impact on the cracktro (like corrupting the
	; low memory) is very low.

	move.w	#$2700,sr

	; Disable interrupts that are not supposed to occur
	; when the boot-cracktro is running.
	FIX_INTERRUPTS	a3

	move.w	#$2300,sr

	; Move the GEM Line-F handler to a safe place.
	FIX_LINEF	FATAL_DEST.w,LINEF_DEST.w

	; Patch the TOS variable that points to the current
	; basepage to make it point to the initial basepage.
	FIX_CURR_BPAGE	a6
	; At the end of the macro, a1 = address of the TOS
	; variable or NULL if not found.

	; Disable Trap #1 if the TOS variable has not been patched
	; and if the cracktro is executed from a low address (which
	; could lead to corrupt the current basepage).
	; See the FIX_CURR_BPAGE() macro for details.
	; Always disable Trap #2 which is not supposed to be used
	; by the boot-cracktro.
	move.l	a1,d0
	bne.s	.trap2
	lea	intro_preamble+$100(pc),a1
	cmpa.l	intro_start_addr(pc),a1
	bls.s	.trap2
	move.l	a4,$84.w        ; Trap #1
.trap2	move.l	a4,$88.w        ; Trap #2

	; Install a dummy handler (simple rts) in the internal
	; mouse vector of the TOS.
	; This ensures that the mouse handler previously installed
	; by the VDI, which could corrupt the low user memory used
	; by the boot-cracktro, will no longer be called.
	; But it also makes sure that the mouse is still enabled
	; on the IKBD for the cracktro.
	; This trick is necessary especially on EmuTOS where
	; _membot is located higher in memory.

	; Get the internal IKBD vectors (KBDVBASE).
	move.w	#34,-(a7)       ; Kbdvbase
	trap	#14
	addq.l	#2,a7

	; Patch the mouse vector.
	movea.l	d0,a0           ; KBDVBASE
	lea	2(a5),a1        ; rts in ROM
.kb_fix	move	#$2700,sr       ; Mask interrupts
	move.b	(9*4)(a0),d0    ; IKBD driver status
	bne.s	.kb_sr          ; In-transit packet?
	move.l	a1,(4*4)(a0)    ; No, patch kb_mousevec
.kb_sr	move	#$2300,sr       ; Unmask interrupts
	tst.b	d0              ; Yes, retry
	bne.s	.kb_fix

	; Disable the GEM Event timer handler.
	move.l	a1,$400.w       ; GEM Event timer handler

	; Disable the GEM Critical error handler.
	move.l	a5,$404.w       ; GEM Critical error hdl

	; Disable Hard Disk Driver operations and thus ensure
	; that no unexpected and possibly risky access to hard
	; disks will be performed.
	move.l	a5,$46a.w       ; hdv_init
	move.l	a5,$472.w       ; hdv_bpb
	move.l	a5,$476.w       ; hdv_rw
	move.l	a5,$47a.w       ; hdv_boot
	move.l	a5,$47e.w       ; hdv_mediach

	; Hide Hard Disk units and force the boot device to DRV A.
	clr.w	$446.w          ; _bootdev
	move.w	#1,$4a6.w       ; _nflops
	move.l	#3,$4c2.w       ; _drvbits

	; Set up the screen as it was configured by the
	; bootsector before executing the boot-cracktro.
	move.w	intro_rez(pc),-(a7)
	move.l	intro_vbase(pc),-(a7)
	move.l	intro_vbase(pc),-(a7)
	move.w	#5,-(a7)
	trap	#14
	lea	12(a7),a7

	movem.l	intro_pal(pc),d0-d7
	movem.l	d0-d7,-(a7)

	move.w	#$2700,sr

	; Simulate a half-meg machine.
	clr.l	$420.w          ; memvalid
	move.b	#4,$424.w       ; memctrl
	move.l	#$80000,$42e.w  ; phystop
	move.l	#$78000,$436.w  ; _memtop
	clr.l	$43a.w          ; memval2
	clr.l	$51a.w          ; memval3
	move.l	#MEMBOT,$432.w  ; _membot
	move.l	$432.w,$4fa.w   ; end_os

	move.w	#$2300,sr

	; Is the ripped cracktro a GEMDOS PRG (that needs to be
	; relocated)?
	lea	intro_entry_point(pc),a0
	move.l	intro_text_offset(pc),d3
	beq.s	.exec_tramp

	; Yes, handle the relocation/fixup table.
.prg	move.l	2(a0),d0        ; PRG text size
	add.l	6(a0),d0        ; PRG data size
	lea	$1c(a0,d0.l),a2 ; Start of BSS if any
	add.l	14(a0),d0       ; PRG symbol table size
	lea	$1c(a0,d0.l),a1 ; Start of fixup table
	tst.w	$1a(a0)         ; ph_absflag = 0?
	bne.s	.erel           ;  if not, no fixup table
	moveq.l	#0,d1
	moveq.l	#$1c,d2         ; d2 = dest. prog address
	add.l	intro_start_addr(pc),d2
	move.l	(a1)+,d0        ; 1st fixup longword = 0?
	beq.s	.erel           ;  if yes, no fixup table
.rel1	add.l	d2,$1c(a0,d0.l) ; Fixup the address
.rel2	move.b	(a1)+,d1        ; Next fixup offset
	beq.s	.erel           ; If 0, end of fixup table
	add.l	d1,d0           ; Offset to next address
	cmpi.b	#1,d1           ; If 1, advance 254 bytes
	bne.s	.rel1
	addi.l	#253,d0
	bra.s	.rel2
.erel
	; The trampoline code copies the cracktro and clears the
	; memory after it (including BSS) in 8 byte increments.
	; So, make sure that the first 8 bytes of the BSS section,
	; which is not necessarily aligned to an 8 byte boundary
	; from the beginning of the cracktro, are cleared.
	clr.l	(a2)+
	clr.l	(a2)+

.exec_tramp
	; Initialize the registers passed to the trampoline
	; routine as follows:
	; a0 = cracktro source address (already initialized)
	; a1 = cracktro destination address
	; a2 = upper limit for memory clearing
	; d0 = cracktro size
	; d1 = number of iterations required to copy
	;      the cracktro in 8-byte increments.
	; d3 = cracktro Text offset: $1c or 0 (already initialized)
	; d7 = cracktro SR
	; a5 = cracktro SSP
	; a6 = cracktro USP
	movea.l	intro_start_addr(pc),a1
	lea	$7fd00,a2
	move.l	intro_size(pc),d0
	move.l	d0,d1
	lsr.l	#3,d1
	subq.l	#1,d1
	movem.l	intro_sr(pc),d7/a5-a6

	; Execute the trampoline.
	jmp	TRAMP_DEST.w

	;
	; Resident code that is copied in the system crash page.
	;
.resid_start
	;
	; Trampoline code that installs and launches the cracktro.
	; The destination address where the cracktro is copied is
	; the same address where it is normally loaded and executed
	; by the bootsector.
	;
.tramp
	cmpa.l	a0,a1
	bls.s	.cp_fwd

	; Copy the cracktro backwards
	; if destination address > source address.
	adda.l	d0,a0
	adda.l	d0,a1
.cp_bwd	move.l	-(a0),-(a1)
	move.l	-(a0),-(a1)
	dbf	d1,.cp_bwd
	movea.l	a1,a0
	adda.l	d0,a1
	bra.s	.cp_end

.cp_fwd	; Copy the cracktro forward
	; if destination address <= source address.
	move.l	(a0)+,(a1)+
	move.l	(a0)+,(a1)+
	dbf	d1,.cp_fwd
	movea.l	a1,a0
	suba.l	d0,a0

.cp_end	; Do not touch the memory below MEMBOT_MIN and thus make
	; sure that the TOS variable pointing to the current
	; basepage is not corrupted.
	cmpa.l	#MEMBOT_MIN,a1
	bhs.s	.clear
	movea.l	#MEMBOT_MIN,a1

.clear	; Clear the memory after the cracktro, including BSS.
	clr.l	(a1)+
	clr.l	(a1)+
	clr.l	(a1)+
	clr.l	(a1)+
	cmpa.l	a2,a1
	blo.s	.clear

	; Simulate a fake basepage containing only the start
	; address and size of the Text section (needed by some
	; self-unpacking cracktros).
	; The fake basepage is created only if it is located
	; above MEMBOT_MIN.
	; a0 = cracktro start address
	; d0 = cracktro size
	; d3 = cracktro Text offset: $1c or 0
	suba.l	a1,a1
	cmpa.l	#MEMBOT_MIN+$100,a0
	blo.s	.pal
	movea.l	a0,a1
	move.w	#$100,d1
	sub.w	d3,d1
	lsr.w	#2,d1
	subq.w	#1,d1
.bpage	clr.l	-(a1)
	dbf	d1,.bpage
	; a1 = fake basepage
	sub.l	d3,d0
	move.l	d0,$c(a1)       ; Text section length
	adda.l	d3,a0
	move.l	a0,$8(a1)       ; Text section start

.pal	; Set up the screen palette as it was set by the
	; original bootsector before starting the cracktro.
	movem.l	(a7)+,d0-d6/a3
	movem.l	d0-d6/a3,$ffff8240.w

	; Mask interrupts.
	move	#$2700,sr

	; Set SR, SSP and USP as they were set by the original
	; bootsector before starting the cracktro.
	move.l	a5,d0
	beq.s	.tst_sr
	movea.l	a5,a7           ; Set SSP if != 0
.tst_sr	btst	#$d,d7          ; Bit S of SR
	beq.s	.user
.ssp	subq.l	#8,a7
	movea.l	a7,a5           ; a5 = cracktro SP
	bra.s	.usp
.user	subq.l	#8,a6
	movea.l	a6,a5           ; a5 = cracktro SP
.usp	move	a6,usp          ; Set USP

	; Save the basepage address into the stack, to simulate
	; a GEMDOS startup (again necessary for some cracktros
	; with self-unpacking).
.sav_bp	clr.l	(a5)+           ; Cracktro SP
	move.l	a1,(a5)

	; Simulate a return from exception to jump to the cracktro
	; entry point in the expected CPU mode (User or Super).
	move.l	#TRAMP_DEST+(.trap0-.tramp),$80.w
	trap	#0
.trap0	move.l	a0,2(a7)        ; Return address
	move.w	d7,(a7)         ; SR

	; Clear the registers.
	movem.l	-(16*4)(a2),d0-d7/a0-a6

	; Go!
	rte

	;
	; Resident routine executed in case of a CPU exception.
	;
.fatal
	move.w	#$2700,sr
	move.w	#$700,$ffff8240.w
.dead	bra.s	.dead

	;
	; Resident handler used to disable Trap #1 and Trap #2.
	;
.trap_err
	moveq.l	#-1,d0          ; Generic error
	rte

	;
	; Resident handler used to disable Hard Disk operations
	; and GEM Critical error handling.
	;
.hdv_err
	moveq.l	#-1,d0          ; Generic error
	rts

.resid_end

	; Addresses of resident routines in the system crash page.
RESID_TOP       =	$3fc
LINEF_DEST      =	(RESID_TOP-LINEF_TRAMP_SIZE)
HDV_ERR_DEST    =	(LINEF_DEST-(.resid_end-.hdv_err))
TRAP_ERR_DEST   =	(HDV_ERR_DEST-(.hdv_err-.trap_err))
FATAL_DEST      =	(TRAP_ERR_DEST-(.trap_err-.fatal))
TRAMP_DEST      =	(FATAL_DEST-(.fatal-.tramp))

	; Clear the screen.
.cls	dc.b	27,"E",27,"Y",32,32,27,"f",0
	even
	; Screen resolution as set by the original bootloader.
intro_rez:
	ds.w	1
	; Screen address as set by the original bootloader.
intro_vbase:
	ds.l	1
	; Screen palette as set by the original bootloader.
intro_pal:
	ds.w	16
	; Cracktro execution address as defined by the original
	; bootloader.
intro_start_addr:
	ds.l	1
	; Cracktro size (without the relocation/fixup table).
intro_size:
	ds.l	1
	; Indicate whether the cracktro is a GEMDOS PRG
	; (offset = $1c) or a raw binary (offset = 0).
intro_text_offset:
	ds.l	1
	; Status register as set by the original bootloader.
intro_sr:
	ds.w	2
	; Supervisor Stack Pointer as set by the original
	; bootloader.
intro_ssp:
	ds.l	1
	; User Stack Pointer as set by the original bootloader.
intro_usp:
	ds.l	1
	; Indicate the beginning of the cracktro binary.
	dc.b	"/!\ The original binary file starts here ==>"
	even
	; The ripped cracktro is concatenated here.
intro_entry_point:
intro_preamble_end:

	;
	; Boot analysis - Available in debug mode only.
	;
	ifne	DBG_BOOT_ANALYSIS

	;
	; analyze()
	;
	; This routine is called by the main menu when the
	; option "Boot analysis [Debug]" is selected.
	;
	; It examines how the bootsector loads and starts the
	; boot-cracktro and prints a detailed report.
	;
	; This function performs the same operations as the rip()
	; function, i.e. it executes the bootsector in the sandbox
	; in order to rip the cracktro, but instead of saving the
	; cracktro that has just been ripped, it displays a report
	; on the characteristics of the cracktro binary and how it
	; was loaded.
	;
	; This function is used for debug purposes.
	;
analyze:
	movem.l	d0-d2/a0-a2,-(a7)

	; Print the message asking to insert the disk and wait
	; for a keystroke.
	lea	txt_rip_start(pc),a0
	bsr	print
	bsr	readchar

	bsr	cls

	; Read the bootsector and check if it is executable.
	bsr	boot_read
	; If the bootsector is executable, run it in the sandbox.
	tst.l	d0
	beq.s	.exec
	; If it is not executable, check if the disk contains
	; regular files.
	cmpi.w	#ENOBOOT,d0
	beq	.check_file
	; If the bootsector cannot be read, print an error message.
	lea	txt_boot_err(pc),a0
	bra	.msg_ret

	; The bootsector is executable, create a sandbox and
	; run the bootsector until a cracktro is ripped.
.exec	lea	exec_boot(pc),a0
	lea	bootsector_trampoline(pc),a1
	bsr	supexec

	bsr	cls

	; Check if an error occurred during the "ripping" work.
	tst.l	d0
	beq.s	.chk_load
	; An error occurred, print a message of error.
	lea	txt_rip_err(pc),a0
	bra	.msg_ret
.chk_load
	; Check if a cracktro was loaded by the bootsector.
	lea	intro_load_addr(pc),a0
	tst.l	(a0)
	; If no cracktro was loaded, check if the disk contains
	; regular files.
	beq	.check_file
.info_boot
	; A cracktro was loaded by the bootsector and no error
	; occurred, print detailed information about the ripped
	; cracktro.
	lea	txt_boot_info(pc),a0
	bsr	print

	lea	txt_pos(pc),a0
	move.b	#32+2,2(a0)

	; Print the cracktro type:
	; - Raw binary (no fixup info)
	; - Absolute PRG (no fixup info)
	; - Relocatable PRG (with fixup info)
	lea	txt_type_bin(pc),a1
	move.l	intro_prg_size(pc),d0
	beq.s	.type
	lea	txt_type_prg_nofixup(pc),a1
	movea.l	intro_buf_rel(pc),a0
	tst.w	$1a(a0)
	bne.s	.type
	move.l	2(a0),d0
	add.l	6(a0),d0
	add.l	14(a0),d0
	tst.l	$1c(a0,d0.l)
	beq.s	.type
	lea	txt_type_prg(pc),a1
.type	lea	txt_type(pc),a0
	bsr	print_info

	; Print the cracktro execution address.
	lea	txt_addr(pc),a0
	move.l	intro_load_addr(pc),d0
	bsr	print_reg

	; Print the cracktro size.
	lea	txt_size(pc),a0
	move.l	intro_prg_size(pc),d0
	bne.s	.size
	move.l	intro_buf_next(pc),d0
	sub.l	intro_buf_rel(pc),d0
.size	bsr	print_reg

	; Indicate which TOS function was used to load the
	; cracktro: XBios Floprd or Bios Rwabs.
	lea	txt_load_func(pc),a0
	lea	txt_load_floprd(pc),a1
	move.w	use_rwabs(pc),d0
	beq.s	.ldfunc
	lea	txt_load_rwabs(pc),a1
.ldfunc	bsr.s	print_info

	; Print the value of SR when the cracktro was loaded.
	lea	txt_sr_load(pc),a0
	moveq.l	#0,d0
	move.w	sr_load(pc),d0
	bsr	print_reg

	; Print the value of SR when the cracktro was executed.
	lea	txt_sr_start(pc),a0
	moveq.l	#0,d0
	move.w	sr_start(pc),d0
	bne.s	.sr
	lea	txt_unknown(pc),a1
	bsr.s	print_info
	bra.s	.sr_ct
.sr	bsr	print_reg
.sr_ct
	; Print the value of the Trace vector when the cracktro
	; was loaded.
	lea	txt_trace_load(pc),a0
	move.l	trace_load(pc),d0
	bsr	print_reg

	; Print the type of protection used by the bootsector
	; if any.
	lea	txt_prot_type(pc),a0
	lea	txt_prots(pc),a1
	move.w	prot_type(pc),d0
	lsl.w	#2,d0
	adda.l	(a1,d0.w),a1
	bsr.s	print_info

	; Add a newline.
	lea	txt_newline(pc),a0
	bsr	print
	bra.s	.msg_ret

.check_file
	; Indicate if the disk contains regular files.
	bsr	check_files
	lea	txt_files(pc),a0
	tst.l	d0
	beq.s	.msg_ret
	lea	txt_nofile(pc),a0

.msg_ret
	; Print the message passed in a0 followed by the end
	; message (asking to press a key) and wait for a
	; keystroke to return to the main menu.
	bsr	print
	lea	txt_return_main(pc),a0
	bsr	print
	bsr	readchar

	bsr	cls

.ret	movem.l	(a7)+,d0-d2/a0-a2
	rts

	;
	; print_info()
	;
	; Print an information text and its caption.
	;
	; In:
	;   a1: information text
	;   a0: corresponding caption
	;
print_info:
	movem.l	a0-a2,-(a7)

	; Current position of the text on the screen.
	lea	txt_pos(pc),a2

	; Set the position of the caption.
	exg.l	a2,a0
	move.b	#32+0,3(a0)
	bsr	print

	; Print the caption.
	exg.l	a2,a0
	bsr	print

	; Set the position of the information text.
	exg.l	a2,a0
	move.b	#32+20,3(a0)
	bsr	print

	; Print the information text.
	exg.l	a1,a0
	bsr	print

	; The next message will be printed on the next line.
	addq.b	#1,2(a1)

	movem.l	(a7)+,a0-a2
	rts

	;
	; print_reg()
	;
	; Print a 32-bit value and its caption.
	;
	; In:
	;   d0: 32-bit value to be printed
	;   a0: corresponding caption
	;
print_reg:
	movem.l	a0-a1,-(a7)

	; Current position of the text on the screen.
	lea	txt_pos(pc),a1

	; Set the position of the caption.
	exg.l	a1,a0
	move.b	#32+0,3(a0)
	bsr	print

	; Print the caption.
	exg.l	a1,a0
	bsr	print

	; Set the position of the 32-bit value.
	exg.l	a1,a0
	move.b	#32+20,3(a0)
	bsr	print

	; Print the 32-bit value.
	bsr.s	print_reg_val

	; The next message will be printed on the next line.
	addq.b	#1,2(a0)

	movem.l	(a7)+,a0-a1
	rts

	;
	; print_reg_val()
	;
	; Print a 32-bit value.
	;
	; In:
	;   d0: 32-bit value to be printed
	;
print_reg_val:
	movem.l	d0-d2/a0-a1,-(a7)

	; Convert the 32-bit value to a printable string.
	lea	reg_val(pc),a0
	lea	1(a0),a1
	moveq.l	#7,d1

.next	rol.l	#4,d0
	move.b	d0,d2
	andi.b	#$f,d2
	cmpi.b	#$9,d2
	bls.s	.num
	addq.b	#'A'-'0'-$a,d2
.num	addi.b	#'0',d2
	move.b	d2,(a1)+
	dbf	d1,.next

	; Print the resulting string.
	bsr	print

	movem.l	(a7)+,d0-d2/a0-a1
	rts

	;
	; Types of protection used by the bootsector.
	;
PROT_NONE            =	0
PROT_ILLEGAL_TVD     =	1
PROT_ILLEGAL_CLEAR   =	2

	section	data

	;
	; Debugging/analysis information.
	;
use_rwabs:
	dc.w	0
sr_load:
	dc.w	0
sr_start:
	dc.w	0
trace_load:
	dc.l	0
prot_type:
	dc.w	0

	;
	; Debugging/analysis messages.
	;
reg_val:
	dc.b	"$00000000",0
	even
txt_pos:
	dc.b	27,"Y",32,32,0
	even
txt_type:
	dc.b	"Cracktro Type",0
	even
txt_type_bin:
	dc.b	"Raw Binary",0
	even
txt_type_prg:
	dc.b	"PRG [Fixup info]",0
	even
txt_type_prg_nofixup:
	dc.b	"PRG [Absolute]",0
	even
txt_addr:
	dc.b	"Cracktro Address",0
	even
txt_size:
	dc.b	"Cracktro Size",0
	even
txt_load_func:
	dc.b	"Load Function",0
	even
txt_load_floprd:
	dc.b	"Floprd",0
	even
txt_load_rwabs:
	dc.b	"Rwabs",0
	even
txt_sr_load:
	dc.b	"Load-time SR",0
	even
txt_sr_start:
	dc.b	"Start-time SR",0
	even
txt_trace_load:
	dc.b	"Trace Vector",0
	even
txt_prot_type:
	dc.b	"Protection",0
	even
txt_prot_none:
	dc.b	"None",0
	even
txt_prot_illegal_tvd:
	dc.b	"Illegal TVD",0
	even
txt_prot_illegal_clear:
	dc.b	"Illegal Clear",0
	even
txt_prots:
	dc.l	(txt_prot_none-txt_prots)
	dc.l	(txt_prot_illegal_tvd-txt_prots)
	dc.l	(txt_prot_illegal_clear-txt_prots)
txt_unknown:
	dc.b	"Unknown",0
	even
txt_rip_err:
	dc.b	"The boot-cracktro cannot be ripped!",10,13
	dc.b	0
	even
txt_files:
	dc.b	"The disk contains regular files!",10,13
	dc.b	0
	even
txt_boot_info:
	dc.b	"The disk contains a boot-cracktro",10,13
	dc.b	0
	even

	section	text

	endc	; DBG_BOOT_ANALYSIS

	;
	; Self-tests - Available in debug mode only.
	;
	; Verify that the mechanisms for "ripping" a cracktro
	; are working properly.
	;
	ifne	DBG_SELFTESTS

	;
	; SELFTEST_OK()
	;
	; Indicate that the test case has reached an expected
	; code statement.
	;
	; In:
	;   param1: scratch register
	;
SELFTEST_OK	macro	
	lea	step_ok(pc),\1
	st	(\1)
	endm

	;
	; SELFTEST_KO()
	;
	; Indicate that the test case has reached an unexpected
	; code statement.
	;
	; In:
	;   param1: scratch register
	;
SELFTEST_KO	macro	
	lea	step_ko(pc),\1
	st	(\1)
	endm

	;
	; TRAP14_STUB()
	;
	; Hook the XBios vector to install a test handler that
	; mimics the Floprd and Flopver functions without using
	; the floppy drive.
	;
	; In:
	;   param1: test handler
	;   param2: scratch register
	;
TRAP14_STUB	macro
	lea	\1(pc),\2
	move.l	(trap14_jmp+2-\1)(\2),(trap14_tests_jmp+2-\1)(\2)
	move.l	\2,(trap14_jmp+2-\1)(\2)
	endm

	;
	; TRAP14_UNSTUB()
	;
	; Remove the hook previously installed by the
	; TRAP14_STUB() macro.
	;
	; In:
	;   param1: scratch register
	;
TRAP14_UNSTUB	macro
	lea	trap14_tests_jmp+2(pc),\1
	move.l	(\1),(trap14_jmp-trap14_tests_jmp)(\1)
	endm

	;
	; set_regs()
	;
	; Initialize the registers with specific values
	; that will be checked later.
	; Also save the stack pointer for later verification.
	;
set_regs:
	move.l	#$11111111,d1
	move.l	#$22222222,d2
	move.l	#$33333333,d3
	move.l	#$44444444,d4
	move.l	#$55555555,d5
	move.l	#$66666666,d6
	move.l	#$77777777,d7
	lea	chk_sp(pc),a0
	move.l	a7,2(a0)
	movea.l	#$00000000,a0
	movea.l	#$11111111,a1
	movea.l	#$22222222,a2
	movea.l	#$33333333,a3
	movea.l	#$44444444,a4
	movea.l	#$55555555,a5
	movea.l	#$66666666,a6
	rts

	;
	; check_regs()
	;
	; Check that d3-d7/a3-a6 registers still have the specific
	; values initialized at the beginning of the test.
	; This verifies that hooked Bios and XBios functions still
	; respect the TOS calling convention.
	; Also check that the stack pointer did not change.
	;
check_regs:
	cmpi.l	#$33333333,d3
	bne	exec_boot_err
	cmpi.l	#$44444444,d4
	bne	exec_boot_err
	cmpi.l	#$55555555,d5
	bne	exec_boot_err
	cmpi.l	#$66666666,d6
	bne	exec_boot_err
	cmpi.l	#$77777777,d7
	bne	exec_boot_err
	cmpa.l	#$33333333,a3
	bne	exec_boot_err
	cmpa.l	#$44444444,a4
	bne	exec_boot_err
	cmpa.l	#$55555555,a5
	bne	exec_boot_err
	cmpa.l	#$66666666,a6
	bne	exec_boot_err
chk_sp:	cmpa.l	#$0,a7
	bne	exec_boot_err
	rts

	;
	; trap14_tests()
	;
	; XBios Vector Hook used for testing.
	;
	; It mimics the Floprd and Flopver functions without using
	; the floppy drive.
	; This is useful for self-tests which then do not need
	; a test disk, as it is emulated by this test handler.
	;
trap14_tests:
	lea	6(a7),a0
	btst	#13,(a7)
	bne.s	.sup
	move.l	usp,a0
.sup
	cmpi.w	#8,(a0)         ; Floprd
	beq.s	.op_ok
	cmpi.w	#19,(a0)        ; Flopver
	bne.s	trap14_tests_jmp

	; Maximum supported disk geometry.
.op_ok	tst.w	10(a0)          ; DRV A
	bne.s	.err
	cmpi.w	#36,12(a0)      ; Sector number
	bhi.s	.err
	cmpi.w	#84,14(a0)      ; Track number
	bhi.s	.err
	cmpi.w	#1,16(a0)       ; Side
	bhi.s	.err
	cmpi.w	#36,18(a0)      ; Sector count
	bhi.s	.err

	; Flopver: return E_OK.
	cmpi.w	#19,(a0)
	beq.s	.ok

	; Floprd: read fake sectors filled with the 'REPS' pattern.
	movea.l	2(a0),a1        ; Transfer buffer
	move.w	18(a0),d0
	lsl.w	#9-2,d0         ; Size in longwords
	subq.w	#1,d0           ; -1 for dbf
.fill	move.l	#'REPS',(a1)+
	dbf	d0,.fill

	; Return to the caller.
.ok	moveq.l	#0,d0           ; E_OK
.ret	moveq.l	#-1,d1          ; Corrupt scratch regs
	move.l	d1,d2
	movea.l	d1,a0
	movea.l	d1,a1
	movea.l	d1,a2
	rte

	; Unsupported operation.
.err	moveq.l	#-1,d0          ; ERROR
	bra.s	.ret

	; Original Trap #14 handler.
trap14_tests_jmp:
	jmp	$0.l

	;
	; selftest1()
	;
	; Check the emulated Bios disk operations:
	; - Mediach
	; - Getbpb
	; - Rwabs (used to load a dummy cracktro binary)
	;
selftest1:
	lea	$15000,a7

	TRAP14_STUB	trap14_tests,a0

	bsr	set_regs

	; Mediach.
	move.w	#0,-(a7)
	move.w	#9,-(a7)
	trap	#13
	addq.l	#4,a7
	tst.l	d0
	bne	exec_boot_err

	; Getbpb.
	move.w	#0,-(a7)
	move.w	#7,-(a7)
	trap	#13
	addq.l	#4,a7
	movea.l	d0,a0
	move.w	(a0),d0
	cmpi.w	#$200,d0
	bne	exec_boot_err
	mulu.w	2(a0),d0
	cmp.w	4(a0),d0
	bne	exec_boot_err

	; Load a dummy cracktro binary using Rwabs.
	clr.l	-(a7)
	move.w	#0,-(a7)
	move.w	12(a0),-(a7)
	move.w	#233,-(a7)
	pea	$20000
	move.w	#0,-(a7)
	move.w	#4,-(a7)
	trap	#13
	lea	18(a7),a7
	tst.l	d0
	bne	exec_boot_err

	bsr	check_regs

	SELFTEST_OK	a0

	jmp	$20000

	;
	; selftest2()
	;
	; Check that an error is triggered when sectors are
	; not loaded contiguously in memory.
	;
selftest2:
	TRAP14_STUB	trap14_tests,a0

	bsr	set_regs

	clr.l	-(a7)
	move.w	#0,-(a7)
	move.w	#25,-(a7)
	move.w	#30,-(a7)
	pea	$20000
	move.w	#0,-(a7)
	move.w	#4,-(a7)
	trap	#13
	lea	18(a7),a7
	tst.l	d0
	bne	exec_boot_err

	bsr	check_regs

	SELFTEST_OK	a0

	clr.l	-(a7)
	move.w	#0,-(a7)
	move.w	#55,-(a7)
	move.w	#25,-(a7)
	pea	$20000
	move.w	#0,-(a7)
	move.w	#4,-(a7)
	trap	#13
	lea	18(a7),a7

	SELFTEST_KO	a0

	rts

	;
	; selftest3()
	;
	; Check that an error is triggered when sectors are
	; loaded above the first 512KB of memory.
	;
selftest3:
	TRAP14_STUB	trap14_tests,a0

	bsr	set_regs

	clr.l	-(a7)
	move.w	#0,-(a7)
	move.w	#50,-(a7)
	move.w	#10,-(a7)
	pea	$80000-(512*25)
	move.w	#0,-(a7)
	move.w	#4,-(a7)
	trap	#13
	lea	18(a7),a7
	tst.l	d0
	bne	exec_boot_err

	clr.l	-(a7)
	move.w	#0,-(a7)
	move.w	#100,-(a7)
	move.w	#10,-(a7)
	pea	$80000-(512*15)
	move.w	#0,-(a7)
	move.w	#4,-(a7)
	trap	#13
	lea	18(a7),a7
	tst.l	d0
	bne	exec_boot_err

	bsr	check_regs

	SELFTEST_OK	a0

	clr.l	-(a7)
	move.w	#0,-(a7)
	move.w	#150,-(a7)
	move.w	#6,-(a7)
	pea	$80000-(512*5)
	move.w	#0,-(a7)
	move.w	#4,-(a7)
	trap	#13
	lea	18(a7),a7

	SELFTEST_KO	a0

	rts

	;
	; selftest4()
	;
	; Check that an error is triggered when the size of
	; the cracktro binary exceeds the size of the buffer
	; where it is saved (INTRO_BUF_SIZE bytes).
	;
selftest4:
	TRAP14_STUB	trap14_tests,a0

	bsr	set_regs

	clr.l	-(a7)
	move.w	#0,-(a7)
	move.w	#100,-(a7)
	move.w	#100,-(a7)
	pea	$20000
	move.w	#0,-(a7)
	move.w	#4,-(a7)
	trap	#13
	lea	18(a7),a7
	tst.l	d0
	bne	exec_boot_err

	bsr	check_regs

	SELFTEST_OK	a0

	clr.l	-(a7)
	move.w	#0,-(a7)
	move.w	#50,-(a7)
	move.w	#(INTRO_BUF_SIZE/512)-100+1,-(a7)
	pea	$20000+(512*100)
	move.w	#0,-(a7)
	move.w	#4,-(a7)
	trap	#13
	lea	18(a7),a7

	SELFTEST_KO	a0

	rts

	;
	; selftest5()
	;
	; Check that an error is triggered when the load
	; and execution addresses are different.
	;
selftest5:
	TRAP14_STUB	trap14_tests,a0

	bsr	set_regs

	clr.l	-(a7)
	move.w	#0,-(a7)
	move.w	#77,-(a7)
	move.w	#99,-(a7)
	pea	$30000
	move.w	#0,-(a7)
	move.w	#4,-(a7)
	trap	#13
	lea	18(a7),a7
	tst.l	d0
	bne	exec_boot_err

	bsr	check_regs

	lea	$30000,a0
	lea	$20000,a1
	move.w	#((512*99)/4)-1,d0
.cp	move.l	(a0)+,(a1)+
	dbf	d0,.cp

	SELFTEST_OK	a0

	jmp	$20000

	;
	; selftest6()
	;
	; Check that the time-C-based watchdog timer works.
	;
selftest6:
	; Disable the VBL handler.
	lea	.rte(pc),a0
	move.l	a0,$70.w

	SELFTEST_OK	a0

.dead	bra.s	.dead
.rte	rte

	;
	; selftest7()
	;
	; Check that the VBL-based watchdog timer works.
	;
selftest7:
	; Disable the timer-C handler.
	lea	.rte(pc),a0
	move.l	a0,$114.w

	SELFTEST_OK	a0

.dead	bra.s	.dead
.rte	rte

	;
	; selftest8()
	;
	; Check that recovery after a CPU crash works.
	;
selftest8:
	; Mask all interrupts.
	move.w	#$2700,sr

	; Corrupt the first 512KB of memory (including interrupt
	; vectors).
	lea	$30.w,a0
	movea.l	$42e.w,a1
	move.l	#$98f65432,d0
.erase	move.l	d0,(a0)+
	cmpa.l	a0,a1
	bhi.s	.erase

	lea	$400.w,a7
	move	a7,usp

	SELFTEST_OK	a0

	; Re-enable interrupts, this will crash the system since
	; interrupt vectors have been corrupted.
	move.w	#$2300,sr

	SELFTEST_KO	a0

.dead	bra.s	.dead

	;
	; load_mixed()
	;
	; Load a dummy cracktro (raw binary) using both Rwabs
	; and Floprd.
	;
	; This helper routine is used by selftest9 and selftest14.
	;
load_mixed:
	; Load the beginning of the cracktro using Rwabs (Bios).
	clr.l	-(a7)
	move.w	#0,-(a7)        ; DRV A
	move.w	#1,-(a7)        ; Start sector
	move.w	#100,-(a7)      ; Sector count
	pea	$20000          ; Transfer buffer
	move.w	#0,-(a7)        ; RW flags
	move.w	#4,-(a7)
	trap	#13
	lea	18(a7),a7
	tst.l	d0
	bne	exec_boot_err

	; Load the rest of the cracktro using Floprd (XBios).
	lea	.track(pc),a0
	move.l	#$20000+(100*512),(.buf-.track+2)(a0)
	move.w	#0,2(a0)

.lp	move.w	#9,-(a7)        ; Sector count
	move.w	#0,-(a7)        ; Side number
.track	move.w	#0,-(a7)        ; Track number
	move.w	#1,-(a7)        ; Sector number
	move.w	#0,-(a7)        ; DRV A
	clr.l	-(a7)
.buf	move.l	#0,-(a7)        ; Transfer buffer
	move.w	#8,-(a7)
	trap	#14
	lea	20(a7),a7
	tst.l	d0
	bne	exec_boot_err

	lea	.track(pc),a0
	addi.l	#9*512,(.buf-.track+2)(a0)
	addq.w	#1,2(a0)        ; Next track
	cmpi.w	#40,2(a0)
	bne.s	.lp

	rts

	;
	; check_lowmem()
	;
	; Verify that the pattern previously written in low user
	; memory is still present and write a new pattern.
	; This is to ensure that the low user memory is not
	; corrupted by the TOS or the GEM.
	;
check_lowmem:
	movem.l	d0-d5/a0,-(a7)

	move.w	#63,d4
.lp1	movea.l	$432.w,a0

	moveq.l	#3,d5
.lp2	lsl.l	#8,d0
	lsl.l	#8,d1
	lsl.l	#8,d2
	lsl.l	#8,d3
	move.b	(a0),d0
	move.b	d0,d1
	addq.b	#1,d1
	move.b	4(a0),d2
	move.b	d2,d3
	addq.b	#1,d3
	dbf	d5,.lp2

	move.w	#$8000/8,d5

.lp3	cmp.l	(a0),d0
	bne	exec_boot_err
	move.l	d1,(a0)+
	cmp.l	(a0),d2
	bne	exec_boot_err
	move.l	d3,(a0)+
	dbf	d5,.lp3

	lea	timecounters(pc),a0
	move.l	(a0),(timestamps-timecounters)(a0)

	dbf	d4,.lp1

	movem.l	(a7)+,d0-d5/a0
	rts

	;
	; selftest9()
	;
	; Check that the low user memory is fully available for
	; the bootsector: it is possible to write to it without
	; impacting the TOS and the TOS (more specifically the
	; GEM) does not modify it.
	;
selftest9:
	TRAP14_STUB	trap14_tests,a0

	bsr	set_regs

	; Write a pattern to the low user memory.
	movea.l	$432.w,a0
	move.l	#$80000-(16*2),d0
	sub.l	a0,d0
	lsr.l	#4,d0
.w_lmem	move.l	#$77777777,(a0)+
	move.l	#$ffffffff,(a0)+
	move.l	#$77777777,(a0)+
	move.l	#$ffffffff,(a0)+
	dbf	d0,.w_lmem

	; Check the Sversion function of the GEMDOS.
	move.w	#48,-(a7)
	trap	#1
	addq.l	#2,a7
	tst.l	d0
	bmi	exec_boot_err

	bsr	check_lowmem

	; Check the Super function of the GEMDOS.
	move.l	a7,$80.w
	move.w	#$300,sr

	clr.l	-(a7)
	move.w	#$20,-(a7)
	trap	#1
	addq.l	#6,a7

	movea.l	$80.w,a7

	bsr	check_lowmem

	; Check the Cconws function of the GEMDOS.
	bset	#2,$484.w       ; Enable system bell
	bsr.s	.prnt
	dc.b	' ',8,7,0       ; Space, backspace, bell
	even
.prnt	move.w	#9,-(a7)
	trap	#1
	addq.l	#6,a7

	bsr	check_lowmem

	; Check the Cconis function of the GEMDOS.
	moveq.l	#1,d0
	move.w	#11,-(a7)
	trap	#1
	addq.l	#2,a7
	tst.l	d0
	beq.s	.getdat
	cmpi.l	#-1,d0
	bne	exec_boot_err
.getdat
	bsr	check_lowmem

	; Check the Tgetdate function of the GEMDOS.
	move.w	#42,-(a7)
	trap	#1
	addq.l	#2,a7

	bsr	check_lowmem

	; Check the Dgetdrv function of the GEMDOS.
	moveq.l	#-1,d0
	move.w	#25,-(a7)
	trap	#1
	addq.l	#2,a7
	cmpi.l	#25,d0
	bhi	exec_boot_err

	bsr	check_lowmem

	; Check the Physbase function of the XBios.
	move.w	#2,-(a7)
	trap	#14
	addq.l	#2,a7
	lsr.l	#8,d0
	lea	$ffff8201.w,a0
	movep.w	(a0),d1
	cmp.w	d0,d1
	bne	exec_boot_err

	bsr	check_lowmem

	; Check the Vsync function of the XBios.
	movem.l	d3-d4,-(a7)
	move.l	$4ba.w,d4       ; _hz_200
	moveq.l	#32,d3
.lp	move.w	#$25,-(a7)
	trap	#14
	addq.l	#2,a7
	dbf	d3,.lp
	move.l	$4ba.w,d3       ; _hz_200
	sub.l	d4,d3
	; Max number of _hz_200: 34 VBL at 50 Hz.
	cmpi.l	#((1000*34)/50)/5,d3
	bhi	exec_boot_err
	; Min number of _hz_200: 31 VBL at 60 Hz.
	cmpi.l	#((1000*31)/60)/5,d3
	blo	exec_boot_err
	movem.l	(a7)+,d3-d4

	bsr	check_lowmem

	; Check the Setexc function of the Bios.
	pea	-1.w
	move.w	#46,-(a7)       ; Trap #14 ($b8.w)
	move.w	#5,-(a7)
	trap	#13
	addq.l	#8,a7
	cmp.l	$b8.w,d0
	bne	exec_boot_err

	bsr	check_lowmem

	; Check the Bconstat function of the Bios.
	moveq.l	#1,d0
	move.w	#2,-(a7)        ; Console
	move.w	#1,-(a7)
	trap	#13
	addq.l	#4,a7
	tst.l	d0
	beq.s	.load
	cmpi.l	#-1,d0
	bne	exec_boot_err
.load
	bsr	check_lowmem

	; Check Rwabs and Floprd (to load a dummy cracktro).
	bsr	load_mixed

	bsr	check_lowmem

	bsr	check_regs

	SELFTEST_OK	a0

	jmp	$20000

	;
	; trap14_test_prg()
	;
	; Test handler that replaces the original XBios handler
	; for selftest10 to selftest13 only, in order to emulate
	; the loading of a GEMDOS PRG via the Floprd function.
	;
	; This allows to check:
	; - The detection (on-the-fly) of the loading of a
	;   GEMDOS PRG.
	; - The estimation of its size.
	; - The detection and check of the relocation/fixup table
	;   at the end of the loading.
	;

TEST_PRG_LOAD_ADDR    =	$20000
TEST_PRG_FIXUP_SIZE   =	(4+(512*15)+(512-400)+62+1)
TEST_PRG_SECTORS      =	128
TEST_PRG_SIZE         =	((512*(TEST_PRG_SECTORS-15-2))+400+TEST_PRG_FIXUP_SIZE)

trap14_test_prg:
	lea	6(a7),a0
	cmpi.w	#8,(a0)         ; Floprd
	bne	exec_boot_err
	tst.w	10(a0)          ; DRV A
	bne	exec_boot_err

	movea.l	2(a0),a1        ; Transfer buffer
	cmpa.l	#TEST_PRG_LOAD_ADDR,a1
	bne.s	.ret

	;
	; We cheat a little here for the sake of simplicity:
	; The first time the Floprd function is called (for
	; loading the first sectors), we simulate the complete
	; loading of the GEMDOS PRG. The next calls to Floprd
	; (for loading the following sectors) are then simply
	; handled as NOPs.
	;

	; Write the PRG body. It is filled with zeroes.
	move.w	#(TEST_PRG_SECTORS*512)/4-1,d0
	movea.l	a1,a2
.clear	clr.l	(a2)+
	dbf	d0,.clear

	; Write the PRG header.
	move.w	#$601a,(a1)
	move.l	#(TEST_PRG_SIZE-($1c+TEST_PRG_FIXUP_SIZE)),2(a1)

	; Write the PRG relocation/fixup table.
	adda.l	#(TEST_PRG_SIZE-TEST_PRG_FIXUP_SIZE),a1
	move.w	#(TEST_PRG_FIXUP_SIZE-4-1)-1,d0
	move.l	#6,(a1)+
.fixup	move.b	#6,(a1)+
	dbf	d0,.fixup
	clr.b	(a1)+
	; Add garbage after the ending zero.
	move.b	#$ff,(a1)+

	; Return to the caller
.ret	moveq.l	#0,d0           ; E_OK
	moveq.l	#-1,d1          ; Corrupt scratch regs
	move.l	d1,d2
	movea.l	d1,a0
	movea.l	d1,a1
	movea.l	d1,a2
	rte

	;
	; selftest10()
	;
	; Check that a GEMDOS PRG loaded via the Floprd function
	; of the XBios is correctly ripped.
	;
selftest10:
	TRAP14_STUB	trap14_test_prg,a0

	bsr	set_regs

	clr.l	-(a7)
	move.w	#0,-(a7)
	move.w	#16,-(a7)
	move.w	#TEST_PRG_SECTORS,-(a7)
	pea	$20000
	move.w	#0,-(a7)
	move.w	#4,-(a7)
	trap	#13
	lea	18(a7),a7

	bsr	check_regs

	SELFTEST_OK	a0

	jmp	$20000

	;
	; selftest11()
	;
	; Check that an error is triggered when a GEMDOS PRG
	; is incompletely loaded (i.e. is truncated).
	;
selftest11:
	TRAP14_STUB	trap14_test_prg,a0

	bsr	set_regs

	; Use the same generated PRG as in selftest10,
	; but load one less sector.
	clr.l	-(a7)
	move.w	#0,-(a7)
	move.w	#16,-(a7)
	move.w	#TEST_PRG_SECTORS-1,-(a7)
	pea	$20000
	move.w	#0,-(a7)
	move.w	#4,-(a7)
	trap	#13
	lea	18(a7),a7

	bsr	check_regs

	SELFTEST_OK	a0

	jmp	$20000

	;
	; selftest12()
	;
	; Check that a GEMDOS PRG loaded via the Floprd function
	; of the XBios is correctly ripped, even if too many
	; sectors are actually loaded.
	;
selftest12:
	TRAP14_STUB	trap14_test_prg,a0

	bsr	set_regs

	; Use the same generated PRG as in selftest10,
	; but load more sectors than necessary.
	clr.l	-(a7)
	move.w	#0,-(a7)
	move.w	#16,-(a7)
	move.w	#TEST_PRG_SECTORS+40,-(a7)
	pea	$20000
	move.w	#0,-(a7)
	move.w	#4,-(a7)
	trap	#13
	lea	18(a7),a7

	bsr	check_regs

	SELFTEST_OK	a0

	jmp	$20000

	;
	; selftest13()
	;
	; Check that a GEMDOS PRG with an invalid fixup table
	; is considered a raw binary.
	;
selftest13:
	TRAP14_STUB	trap14_test_prg,a0

	bsr	set_regs

	clr.l	-(a7)
	move.w	#0,-(a7)
	move.w	#16,-(a7)
	move.w	#TEST_PRG_SECTORS-1,-(a7)
	pea	$20000
	move.w	#0,-(a7)
	move.w	#4,-(a7)
	trap	#13
	lea	18(a7),a7

	; Use the same generated PRG as in selftest10,
	; but corrupt the first longword of the fixup table.
	lea	$20000+(TEST_PRG_SIZE-TEST_PRG_FIXUP_SIZE),a0
	cmpi.l	#6,(a0)
	bne	exec_boot_err
	move.l	#$ffffffff,(a0)

	clr.l	-(a7)
	move.w	#0,-(a7)
	move.w	#16+TEST_PRG_SECTORS-1,-(a7)
	move.w	#1,-(a7)
	pea	$20000+((TEST_PRG_SECTORS-1)*512)
	move.w	#0,-(a7)
	move.w	#4,-(a7)
	trap	#13
	lea	18(a7),a7

	bsr	check_regs

	SELFTEST_OK	a0

	jmp	$20000

	;
	; selftest14()
	;
	; Check that the Rwabs function of the Bios and the
	; Floprd function of the XBios are working correctly
	; when used to load a cracktro from user mode.
	;
selftest14:
	; Switch to the user mode.
	move.w	#$300,sr
	lea	$15000,a7

	TRAP14_STUB	trap14_tests,a0

	bsr	set_regs

	bsr	load_mixed

	bsr	check_regs

	SELFTEST_OK	a0

	jmp	$20000+$1c

	;
	; selftest15()
	;
	; Check that an error is raised if the bootsector loads
	; data and returns, meaning that the presumed cracktro
	; is not executed.
	;
selftest15:
	TRAP14_STUB	trap14_tests,a0

	bsr	set_regs

	move.w	#8,-(a7)        ; Sector count
	move.w	#0,-(a7)        ; Side number
	move.w	#2,-(a7)        ; Track number
	move.w	#2,-(a7)        ; Sector number
	move.w	#0,-(a7)        ; DRV A
	clr.l	-(a7)
	move.l	#$60000,-(a7)   ; Transfer buffer
	move.w	#8,-(a7)
	trap	#14
	lea	20(a7),a7
	tst.l	d0
	bne	exec_boot_err

	bsr	check_regs

	SELFTEST_OK	a0

	rts

	;
	; selftest16()
	;
	; Check that an error is raised if the bootsector calls
	; a GEMDOS function that is not supported by the sandbox
	; (i.e. a file function for instance).
	;
selftest16:
	bsr	set_regs

	bsr.s	.prnt
	dc.b	0
	even
.prnt	move.w	#9,-(a7)        ; Cconws
	trap	#1
	addq.l	#6,a7

	bsr	check_regs

	SELFTEST_OK	a0

	clr.w	-(a7)
	bsr.s	.fopen
	dc.b	"test",0
	even
.fopen	move.w	#$3d,-(a7)      ; Fopen
	trap	#1
	addq.l	#8,a7

	SELFTEST_KO	a0

	rts

	;
	; selftest17()
	;
	; Check that all system variables, CPU vectors and
	; registers have been correctly set up by the sandbox.
	;
selftest17:
	bsr	set_regs

	lea	$80000,a0

	cmpa.l	a0,a7           ; SSP
	bls	exec_boot_err

	cmpi.b	#4,$424.w       ; memctrl
	bne	exec_boot_err
	cmpa.l	$42e.w,a0       ; phystop
	bne	exec_boot_err
	cmpi.l	#$78000,$436.w  ; _memtop
	bne	exec_boot_err
	cmpi.l	#$78000,$44e.w  ; _v_bas_ad
	bne	exec_boot_err
	tst.b	$44c.w          ; sshiftmod
	bne	exec_boot_err
	movea.l	$4f2.w,a1       ; _sysbase
	cmpa.l	a1,a0
	bne	exec_boot_err
	movea.l	8(a1),a2        ; os_begin
	move.l	(a1),d0         ; os_entry/os_version
	cmp.l	(a2),d0
	bne	exec_boot_err
	movea.l	$432.w,a1       ; _membot
	cmpa.l	#MEMBOT,a1
	bhi	exec_boot_err
	movea.l	$4fa.w,a1       ; end_os
	cmpa.l	$432.w,a1
	bne	exec_boot_err

	movea.l	tos_curr_basepage(pc),a2
	movea.l	(a2),a2
	cmpa.l	a1,a2
	bhs	exec_boot_err

	tst.l	$426.w          ; resvalid
	bne	exec_boot_err
	tst.l	$420.w          ; memvalid
	bne	exec_boot_err
	tst.l	$43a.w          ; memval2
	bne	exec_boot_err
	tst.l	$51a.w          ; memval3
	bne	exec_boot_err

	tst.w	$446.w          ; _bootdev
	bne	exec_boot_err
	cmpi.w	#1,$4a6.w       ; _nflops
	bne	exec_boot_err
	cmpi.l	#3,$4c2.w       ; _drvbits
	bne	exec_boot_err

	lea	pt_base(pc),a0
	lea	pt_end(pc),a1
	move.l	a1,d1
	lea	.v_tbl(pc),a1
.v_loop	move.w	(a1)+,d0
	beq.s	.v_ok
	movea.w	d0,a2           ; Vector address
	movea.l	(a2),a2         ; Handler address
	cmpa.l	a0,a2           ; >= pt_base?
	blo	exec_boot_err
	cmpa.l	d1,a2           ; < pt_end?
	blo.s	.v_loop
	cmpa.l	#$e00000,a2     ; >= ROM address?
	blo	exec_boot_err
	move.w	(a2),d0         ; 1st handler instr
	cmpi.w	#$4e75,d0       ; rts?
	beq.s	.v_loop
	cmpi.w	#$4e73,d0       ; rte?
	beq.s	.v_loop
	bra	exec_boot_err
.v_tbl	; CPU Exception Vectors.
	dc.w	$8,$c,$10,$14,$18,$1c,$20,$24,$28,$2c
	; Auto-Vector Interrupts.
	dc.w	$68,$70,$78
	; Trap Instruction Vectors.
	dc.w	$84,$88,$b4,$b8
	; User Assigned Interrupt Vectors.
	dc.w	$100,$104,$108,$10c
	dc.w	$110,$114,$11c
	dc.w	$120,$124,$128,$12c
	dc.w	$130,$134,$138,$13c
	; GEM vectors.
	dc.w	$400,$404
	; Hard Disk Vectors.
	dc.w	$46a,$472,$476,$47a,$47e
	; End.
	dc.w	0
.v_ok
	cmpi.l	#$e00000,$118.w ; IKBD/ACIA
	blo	exec_boot_err

	move.w	#34,-(a7)       ; Kbdvbase
	trap	#14
	addq.l	#2,a7
	movea.l	d0,a0           ; KBDVBASE
	movea.l	(4*4)(a0),a1    ; kb_mousevec
	cmpi.w	#$4e75,(a1)     ; rts
	bne	exec_boot_err

	movea.l	$456.w,a0       ; _vblqueue
	move.w	$454.w,d0       ; nvbls
	subq.w	#1,d0
.vblq	tst.l	(a0)+
	bne	exec_boot_err
	dbf	d0,.vblq

	move.b	$fffffa19.w,d0  ; Timer A
	andi.b	#%00001111,d0
	bne	exec_boot_err
	move.b	$fffffa1b.w,d0  ; Timer B
	andi.b	#%00001111,d0
	bne	exec_boot_err
	move.b	$fffffa1d.w,d0  ; Timers C & D
	andi.b	#%00000111,d0
	bne	exec_boot_err

	tst.b	$fffffa07.w     ; Enable A
	bne	exec_boot_err
	tst.b	$fffffa13.w     ; Mask A
	bne	exec_boot_err
	tst.b	$fffffa0b.w     ; Pending A
	bne	exec_boot_err
	tst.b	$fffffa0f.w     ; In-service A
	bne	exec_boot_err

	move.b	$fffffa09.w,d0  ; Enable B
	andi.b	#%10011111,d0
	bne	exec_boot_err
	move.b	$fffffa15.w,d0  ; Mask B
	andi.b	#%10011111,d0
	bne	exec_boot_err
	move.b	$fffffa0d.w,d0  ; Pending B
	andi.b	#%10011111,d0
	bne	exec_boot_err
	move.b	$fffffa11.w,d0  ; In-service B
	andi.b	#%10011111,d0
	bne	exec_boot_err

	bsr	check_regs

	SELFTEST_OK	a0

	rts

	;
	; selftest18()
	;
	; Check that the disabled vectors are actually disabled:
	; Divide by 0, Line-A, Trap #2, Hard Disk ops, GEM Event
	; timer handler and GEM critical error handler.
	;
	; Also check the error paths of various hooks used in the
	; sandbox: Trap #1, Trap #13 and Trap #14.
	;
selftest18:
	TRAP14_STUB	trap14_tests,a0

	bsr	set_regs

	; Check that 'divide by zero' is ignored.
	moveq.l	#0,d0
	divu	d0,d0

	; Check that the Line-A is disabled.
	moveq.l	#-1,d0
	movea.l	d0,a0
	dc.w	$a000
	tst.l	d0
	bne	exec_boot_err
	cmp.l	a0,d0
	bne	exec_boot_err
	move.w	#$4321,d0
	dc.w	$a009
	cmpi.w	#$4321,d0
	bne	exec_boot_err

	; Check that the Trap #1 hook does nothing if the TOS
	; variable that points to the current basepage has not
	; been patched.
	move.l	a3,-(a7)
	lea	tos_curr_basepage(pc),a3
	move.l	(a3),-(a7)
	clr.l	(a3)
	moveq.l	#0,d0
	move.w	#48,-(a7)
	trap	#1
	addq.l	#2,a7
	move.l	(a7)+,(a3)
	movea.l	(a7)+,a3
	cmpi.l	#-32,d0
	bne	exec_boot_err

	; Check that Trap #2 is disabled.
	moveq.l	#0,d0
	trap	#2
	cmpi.l	#-32,d0
	bne	exec_boot_err

	; Check that the GEM Event timer handler is disabled.
	movea.l	$400.w,a0
	cmpi.w	#$4e75,(a0)
	bne	exec_boot_err
	jsr	(a0)

	; Check that the GEM critical error handler is disabled.
	movea.l	$404.w,a0
	cmpi.l	#$70ff4e75,(a0)
	bne	exec_boot_err
	moveq.l	#0,d0
	jsr	(a0)
	cmpi.l	#-1,d0
	bne	exec_boot_err

	; Check that the Mediach, Getbpb and Rwabs functions of
	; the Bios fail if an unsupported operation is requested
	; (DRV B, Write).
	; Verify that, in that case, the hard disk dummy handler
	; is called by the Bios as expected.

	; Mediach + DRV B.
	moveq.l	#0,d0
	move.w	#1,-(a7)        ; DRV B
	move.w	#9,-(a7)        ; Mediach
	trap	#13
	addq.l	#4,a7
	cmpi.l	#-32,d0
	bne	exec_boot_err
	move.l	a0,d0
	bne	exec_boot_err

	; Getbpb + DRV B.
	moveq.l	#-1,d0
	move.w	#1,-(a7)        ; DRV B
	move.w	#7,-(a7)        ; Getbpb
	trap	#13
	addq.l	#4,a7
	tst.l	d0
	bne	exec_boot_err
	move.l	a0,d0
	bne	exec_boot_err

	; Rwabs + Write.
	moveq.l	#0,d0
	clr.l	-(a7)
	move.w	#0,-(a7)        ; DRV A
	move.w	#100,-(a7)
	move.w	#10,-(a7)
	pea	$20000
	move.w	#1,-(a7)        ; Write
	move.w	#4,-(a7)        ; Rwabs
	trap	#13
	lea	18(a7),a7
	cmpi.l	#-32,d0
	bne	exec_boot_err
	move.l	a0,d0
	bne	exec_boot_err

	; Rwabs + DRV B.
	moveq.l	#0,d0
	clr.l	-(a7)
	move.w	#1,-(a7)        ; DRV B
	move.w	#100,-(a7)
	move.w	#10,-(a7)
	pea	$20000
	move.w	#0,-(a7)        ; Read
	move.w	#4,-(a7)        ; Rwabs
	trap	#13
	lea	18(a7),a7
	cmpi.l	#-32,d0
	bne	exec_boot_err
	move.l	a0,d0
	bne	exec_boot_err

	; Check that the Trap #14 post hook behaves as expected
	; when the Floprd function of the XBios fails (invalid
	; disk geometry).
	moveq.l	#0,d0
	move.w	#1,-(a7)
	move.w	#99,-(a7)
	move.w	#99,-(a7)
	move.w	#99,-(a7)
	move.w	#0,-(a7)
	clr.l	-(a7)
	move.l	#$20000,-(a7)
	move.w	#8,-(a7)
	trap	#14
	lea	20(a7),a7
	tst.l	d0
	bpl	exec_boot_err

	; Check that the Trap #14 hook allows the execution
	; of XBios functions that are different from Floprd.
	moveq.l	#-1,d0
	move.w	#1,-(a7)
	move.w	#0,-(a7)
	move.w	#0,-(a7)
	move.w	#1,-(a7)
	move.w	#0,-(a7)
	clr.l	-(a7)
	move.l	#$20000,-(a7)
	move.w	#19,-(a7)       ; Flopver
	trap	#14
	lea	20(a7),a7
	tst.l	d0
	bne	exec_boot_err

	; Call Floprd with an invalid device and check that it
	; succeeds if the TOS is a legacy version but fails if
	; it is EmuTOS.
	; The behavior of the legacy TOS results from the fact
	; that _nflops has been forced to 1 (DRV A only) and that
	; the  disk swapping mechanism has been disabled (thanks
	; to the dummy GEM critical error handler). Consequently,
	; Floprd falls back to DRV A without asking to change the
	; disk.

	TRAP14_UNSTUB	a0              ; Remove the XBios test hook

	moveq.l	#1,d0
	; Read the bootsector.
	move.w	#1,-(a7)
	move.w	#0,-(a7)
	move.w	#0,-(a7)
	move.w	#1,-(a7)
	move.w	#2,-(a7)        ; DRV C
	clr.l	-(a7)
	move.l	#$20200,-(a7)   ; 2nd buffer
	move.w	#8,-(a7)        ; Floprd
	trap	#14
	lea	20(a7),a7

	movea.l	$4f2.w,a0       ; OSHEADER (SYSHDR)
	movea.l	8(a0),a0        ; Real OS base address
	cmpi.l	#'ETOS',$2c(a0) ; EmuTOS?
	beq.s	.emutos
	tst.l	d0              ; OK on a legacy TOS
	bne	exec_boot_err
	move.l	#$20200,(a7)    ; Detected Cracktro entry point
	bra.s	.cont
.emutos	cmpi.l	#-15,d0         ; Unknown device on EmuTOS
	bne	exec_boot_err
.cont
	bsr	check_regs

	SELFTEST_OK	a0

	rts

	;
	; run_test()
	;
	; Run a single self-test.
	;
	; In:
	;   d0: test number
	;   a1: address of the test routine
	;
	; Out:
	;   d0: error code indicating whether the cracktro
	;       was successfully ripped
	;   d1: loading/execution address of the cracktro,
	;       or 0 is no cracktro was loaded
	;
run_test:
	bsr.s	print_test
	lea	step_ok(pc),a0
	clr.l	(a0)
	clr.l	(step_ko-step_ok)(a0)
	st.b	(in_selftest-step_ok)(a0)
	lea	exec_boot(pc),a0
	bsr	supexec
	lea	in_selftest(pc),a0
	sf.b	(a0)
	move.l	intro_load_addr(pc),d1
	rts

	;
	; print_test()
	;
	; Print the test banner (test name + number).
	;
print_test:
	lea	txt_test(pc),a0
	divu.w	#10,d0
	addi.b	#'0',d0
	move.b	d0,(txt_test_num-txt_test+0)(a0)
	swap	d0
	addi.b	#'0',d0
	move.b	d0,(txt_test_num-txt_test+1)(a0)
	bsr	print
	rts

	;
	; print_diag()
	; print_fail()
	;
	; Print the test result.
	;
print_diag:
	lea	step_ok(pc),a0
	tst.l	(a0)
	beq.s	print_fail
	tst.l	(step_ko-step_ok)(a0)
	bne.s	print_fail

	lea	txt_pass(pc),a0
	bsr	print
	rts

print_fail:
	lea	txt_fail(pc),a0
	bsr	print
	rts

	;
	; selftests()
	;
	; This routine is called by the main menu when the
	; option "Selftests [Debug]" is selected.
	;
	; It performs self-tests and is only available in
	; debug mode.
	;
selftests:
	movem.l	d0-d1/a0-a1,-(a7)

	;
	; First step, read the bootsector of the floppy disk.
	;

	lea	txt_test_start(pc),a0
	bsr	print
	bsr	readchar

	bsr	cls

	bsr	boot_read
	tst.l	d0
	beq.s	.test1
	cmpi.w	#ENOBOOT,d0
	beq.s	.test1

	;
	; Second step, run the tests.
	;

	lea	txt_boot_err(pc),a0
	bsr	print
	bra	.ret

.test1	moveq.l	#1,d0
	lea	selftest1(pc),a1
	bsr	run_test
	pea	.test2(pc)
	tst.l	d0
	bne.s	print_fail
	tst.l	d1
	beq.s	print_fail
	bra.s	print_diag

.test2	moveq.l	#2,d0
	lea	selftest2(pc),a1
	bsr	run_test
	pea	.test3(pc)
	tst.l	d0
	beq.s	print_fail
	tst.l	d1
	beq.s	print_fail
	bra.s	print_diag

.test3	moveq.l	#3,d0
	lea	selftest3(pc),a1
	bsr	run_test
	pea	.test4(pc)
	tst.l	d0
	beq.s	print_fail
	tst.l	d1
	beq.s	print_fail
	bra	print_diag

.test4	moveq.l	#4,d0
	lea	selftest4(pc),a1
	bsr	run_test
	pea	.test5(pc)
	tst.l	d0
	beq	print_fail
	tst.l	d1
	beq	print_fail
	bra	print_diag

.test5	moveq.l	#5,d0
	lea	selftest5(pc),a1
	bsr	run_test
	pea	.test6(pc)
	tst.l	d0
	beq	print_fail
	tst.l	d1
	beq	print_fail
	bra	print_diag

.test6	moveq.l	#6,d0
	lea	selftest6(pc),a1
	bsr	run_test
	pea	.test7(pc)
	tst.l	d0
	beq	print_fail
	tst.l	d1
	bne	print_fail
	bra	print_diag

.test7	moveq.l	#7,d0
	lea	selftest7(pc),a1
	bsr	run_test
	pea	.test8(pc)
	tst.l	d0
	beq	print_fail
	tst.l	d1
	bne	print_fail
	bra	print_diag

.test8	moveq.l	#8,d0
	lea	selftest8(pc),a1
	bsr	run_test
	pea	.test9(pc)
	tst.l	d0
	beq	print_fail
	tst.l	d1
	bne	print_fail
	bra	print_diag

.test9	moveq.l	#9,d0
	lea	selftest9(pc),a1
	bsr	run_test
	pea	.test10(pc)
	tst.l	d0
	bne	print_fail
	tst.l	d1
	beq	print_fail
	move.l	intro_prg_size(pc),d1
	bne	print_fail
	move.l	intro_buf_next(pc),d1
	sub.l	intro_buf_rel(pc),d1
	cmpi.l	#(100+(40*9))*512,d1
	bne	print_fail
	bra	print_diag

.test10	moveq.l	#10,d0
	lea	selftest10(pc),a1
	bsr	run_test
	pea	.test11(pc)
	tst.l	d0
	bne	print_fail
	tst.l	d1
	beq	print_fail
	move.l	intro_prg_size(pc),d1
	cmpi.l	#TEST_PRG_SIZE,d1
	bne	print_fail
	move.w	intro_prg_valid(pc),d1
	beq	print_fail
	bra	print_diag

.test11	moveq.l	#11,d0
	lea	selftest11(pc),a1
	bsr	run_test
	pea	.test12(pc)
	tst.l	d0
	beq	print_fail
	tst.l	d1
	beq	print_fail
	move.w	intro_prg_valid(pc),d1
	bne	print_fail
	bra	print_diag

.test12	moveq.l	#12,d0
	lea	selftest12(pc),a1
	bsr	run_test
	pea	.test13(pc)
	tst.l	d0
	bne	print_fail
	tst.l	d1
	beq	print_fail
	move.l	intro_prg_size(pc),d1
	cmpi.l	#TEST_PRG_SIZE,d1
	bne	print_fail
	move.w	intro_prg_valid(pc),d1
	beq	print_fail
	bra	print_diag

.test13	moveq.l	#13,d0
	lea	selftest13(pc),a1
	bsr	run_test
	pea	.test14(pc)
	tst.l	d0
	bne	print_fail
	tst.l	d1
	beq	print_fail
	move.l	intro_prg_size(pc),d1
	bne	print_fail
	move.l	intro_buf_next(pc),d1
	sub.l	intro_buf_rel(pc),d1
	cmpi.l	#(TEST_PRG_SECTORS*512),d1
	bne	print_fail
	bra	print_diag

.test14	moveq.l	#14,d0
	lea	selftest14(pc),a1
	bsr	run_test
	pea	.test15(pc)
	tst.l	d0
	bne	print_fail
	tst.l	d1
	beq	print_fail
	move.l	intro_prg_size(pc),d1
	bne	print_fail
	move.l	intro_buf_next(pc),d1
	sub.l	intro_buf_rel(pc),d1
	cmpi.l	#(100+(40*9))*512,d1
	bne	print_fail
	bra	print_diag

.test15	moveq.l	#15,d0
	lea	selftest15(pc),a1
	bsr	run_test
	pea	.test16(pc)
	tst.l	d0
	beq	print_fail
	tst.l	d1
	beq	print_fail
	bra	print_diag

.test16	moveq.l	#16,d0
	lea	selftest16(pc),a1
	bsr	run_test
	pea	.test17(pc)
	tst.l	d0
	beq	print_fail
	tst.l	d1
	bne	print_fail
	bra	print_diag

.test17	moveq.l	#17,d0
	lea	selftest17(pc),a1
	bsr	run_test
	pea	.test18(pc)
	tst.l	d0
	bne	print_fail
	tst.l	d1
	bne	print_fail
	bra	print_diag

.test18	moveq.l	#18,d0
	lea	selftest18(pc),a1
	bsr	run_test
	pea	.end(pc)
	tst.l	d0
	bne	print_fail
	bra	print_diag

.end	lea	txt_newline(pc),a0
	bsr	print

.ret	lea	txt_return_main(pc),a0
	bsr	print
	bsr	readchar

	movem.l	(a7)+,d0-d1/a0-a1
	rts

	section	data

	; Indicate that a self-test is currently running
	; in the sandbox.
in_selftest:
	ds.w	1
	; != 0 if the test case has reached an expected
	; code statement.
step_ok:
	ds.l	1
	; != 0 if the test case has reached an unexpected
	; code statement.
step_ko:
	ds.l	1

	; Self-tests require the bootsector to be read.
txt_test_start:
	dc.b	"Insert a disk in drive A",10,13
	dc.b	"then press any key to start",10,13
	dc.b	0
	even

	; Test banner.
txt_test:
	dc.b	"Selftest #"
	; fall through
txt_test_num:
	dc.b	"00 ... "
	dc.b	0
	even

	; Test Result.
txt_pass:
	dc.b	"Passed",10,13
	dc.b	0
	even
txt_fail:
	dc.b	27,"p","Failed",27,"q",10,13
	dc.b	0
	even

	endc	; DBG_SELFTESTS

	section	bss

	; Original start address of the program (before being
	; moved to high memory).
pt_base_orig:
	ds.l	1
	; Address in high memory where the program is moved.
pt_base_rel:
	ds.l	1
	; Address in high memory where the cracktro is saved.
intro_buf_rel:
	ds.l	1
	; Address where the low memory is saved.
lowmem_buf_rel:
	ds.l	1
	; Size of the low memory that needs to be saved.
lowmem_size:
	ds.l	1
	; Highest address used by the program (mshrink top addr).
prog_memtop:
	ds.l	1
	; Basepage (process descriptor) of the program.
basepage:
	ds.l	1

	; Address of the 1024-byte disk buffer used by the TOS.
	; Copy of the $4c6 system variable.
_dskbufp:
	ds.l	1
	; Bit allocation for physical drives (bit 0=A, 1=B..)
	; Copy of the $4c2 system variable.
_drvbits:
	ds.l	1

	; Supervisor Stack Pointer saved by exec_boot().
ssp_saved:
	ds.l	1
	; Conterm ($484 system variable) saved by init_sup().
conterm_saved:
	ds.b	1
	; MFP configuration saved when creating the sandbox.
mfp_saved:
	ds.b	5
	even
	; Screen palette saved when creating the sandbox.
pal_saved:
	ds.w	16
	; GEM Line-F handler saved when creating the sandbox.
linef:
	ds.b	LINEF_TRAMP_SIZE
	even
	; Address of the TOS variable that points to the current
	; basepage.
tos_curr_basepage:
	ds.l	1

	; If the ripped cracktro is a PRG: the total size
	; of the PRG including the relocation/fixup table.
	; If the ripped cracktro is a raw binary: 0.
intro_prg_size:
	ds.l	1
	; If the ripped cracktro is a PRG, indicate whether it has
	; been fully loaded, i.e. whether the relocation/fixup
	; table if complete.
	; !0 if the PRG is valid.
intro_prg_valid:
	ds.w	1
	; Loading/execution address of the cracktro.
intro_load_addr:
	ds.l	1
	; Error code indicating whether the cracktro was
	; successfully ripped.
	; 0 if the cracktro was ripped, -1 if an error occurred.
intro_load_err:
	ds.l	1
	; Points to the area (in the buffer used for saving the
	; cracktro) where the current sectors should be saved.
intro_buf_next:
	ds.l	1
	; Expected buffer address of the next Floprd call.
	; Used to check that the transfer buffers passed
	; successively to the Floprd function are contiguous.
trap14_buf_next:
	ds.l	1
	; Watchdog timers: free-run counters and timestamps.
timecounters:
	ds.w	2               ; Timer C, VBL
timestamps:
	ds.w	2               ; Timer C, VBL

	; Pointer to the Line-A parameter block.
linea_param_blk:
	ds.l	1

	; AES initialization flag (init was done if != 0).
aes_initdone:
	ds.w	1
	; AES global array.
aes_global:
	ds.w	16
	; AES control array.
aes_control:
	; Offset 0: function number (opcode)
	; Offset 2: number of elements in intin being sent
	; Offset 4: number of elements in intout being returned
	; Offset 6: number of elements in addrin being sent
	; Offset 8: number of elements in addrout being returned
	ds.w	5
	; AES intin array (input parameters).
aes_intin:
	ds.w	16
	; AES intout array (return values).
aes_intout:
	ds.w	16
	; AES addrin array (input pointers).
aes_addrin:
	ds.l	16
	; AES addrin array (returned pointers).
aes_addrout:
	ds.l	16
aes_params_end:

	; Latest path (directory) selected in the file-selector
	; dialog box for file loading.
fsel_path_load:
	ds.b	256
	; Latest path (directory) selected in the file-selector
	; dialog box for file saving.
fsel_path_save:
	ds.b	256
	; Default filename of the file-selector.
fsel_file:
	ds.b	16
	; Absolute path of the file selected in the
	; file-selector dialog box.
fsel_fullname:
	ds.b	256+16+2
	; Loading case: size of the file which has been loaded.
	; Saving case: size of the file that needs to be saved.
file_size:
	ds.l	1
	; Loading case: content of the file which has been loaded.
	; Saving case: content of the file that needs to be saved.
file_addr:
	ds.l	1
	; Address of the buffer allocated by buf_alloc().
alloc_addr:
	ds.l	1
	; Size of the buffer allocated by buf_alloc().
alloc_size:
	ds.l	1

	; Bios BPB resulting from the conversion of
	; the cached FAT12 BPB.
bios_bpb:
	ds.w	1               ; Bytes per sector
	ds.w	1               ; Sectors per cluster
	ds.w	1               ; Bytes per cluster
	ds.w	1               ; Directory length
	ds.w	1               ; FAT length in sectors
	ds.w	1               ; Start of the 2nd FAT
	ds.w	1               ; 1st free sector
	ds.w	1               ; Total number of clusters
	ds.w	1               ; Flags as a bit-vector

	; Cached FAT12 BPB.
	; See boot_bpb_initial below for a detailed description
	; of the structure layout and initial values.
boot_bpb:
	ds.b	30
	even

	section	data

	; AES parameter block.
aes_pb:
	dc.l	aes_control-aes_pb
	dc.l	aes_global-aes_pb
	dc.l	aes_intin-aes_pb
	dc.l	aes_intout-aes_pb
	dc.l	aes_addrin-aes_pb
	dc.l	aes_addrout-aes_pb
aes_pb_end:

	; Initial values of the cached FAT12 BPB.
	; The following special values are used until a call to
	; the Getbpb function is made, at which point the BPB of
	; the current floppy disk is used.
	; This is consistent with the behavior of the Bios.
boot_bpb_initial:
	ds.b	11              ; OEM/SERIAL
	dc.b	0,2             ; BPS
	dc.b	2               ; SPC
	dc.b	1,0             ; RES
	dc.b	2               ; NFATS
	dc.b	64,0            ; NDIRS
	dc.b	$d0,2           ; NSECS
	dc.b	0               ; MEDIA
	dc.b	2,0             ; SPF
	dc.b	9,0             ; SPT
	dc.b	1,0             ; NHEADS
	dc.b	0,0             ; NHID
boot_bpb_initial_end:
	even

	; Force the detection of media changes.
mediach_forced:
	dc.w	DEV_INVALID

	; Table used to determine the access path in the
	; file-selector of a regular cracktro executable.
path_drv_a_table:
	dc.l	(path_drv_a_root-path_drv_a_table)
	dc.l	(path_drv_a_tos-path_drv_a_table)
	dc.l	(path_drv_a_prg-path_drv_a_table)
	dc.l	(path_drv_a_root-path_drv_a_table)
	dc.l	(path_drv_a_auto-path_drv_a_table)
	dc.l	(path_drv_a_root-path_drv_a_table)
	dc.l	(path_drv_a_prg-path_drv_a_table)
	dc.l	(path_drv_a_root-path_drv_a_table)

	; Possible access paths of a regular cracktro executable
	; (used in the table above).
path_drv_a_root:
	dc.b	"A:\*.*",0
path_drv_a_prg:
	dc.b	"A:\*.PRG",0
path_drv_a_tos:
	dc.b	"A:\*.TOS",0
path_drv_a_auto:
	dc.b	"A:\AUTO\*.PRG",0

	; Initial default access path (in the file-selector) used
	; for saving a cracktro. This path is then replaced with
	; the first valid destination path selected for saving.
path_drv_dest:
	dc.b	"?:\*.*",0
	even

	; Low-resolution color palette.
pal_low:
	dc.w	$0fff,$0f00,$00f0,$0ff0,$000f,$0f0f,$00ff,$0555
	dc.w	$0333,$0f33,$03f3,$0ff3,$033f,$0f3f,$03ff,$0000

	; Clear the screen.
txt_cls:
	dc.b	27,"f",27,"E",27,"Y",32,32,27,"q",27,"w",0
	even
	; Insert a new line.
txt_newline:
	dc.b	10,13,0
	even

	;
	; Self-explanatory messages.
	;

txt_linea_err:
	dc.b	"Line-A initialization failed!",10,13
	dc.b	0
	even
txt_mch_err:
	dc.b	"Machine not supported!",10,13
	dc.b	0
	even
txt_rez_err:
	dc.b	"Screen resolution not supported!",10,13
	dc.b	0
	even
txt_mem_err:
	dc.b	"Not enough memory!",10,13
	dc.b	0
	even
txt_vecs_err:
	dc.b	"Critical vectors in low memory!",10,13
	dc.b	0
	even
txt_aes_err:
	dc.b	"AES initialization failed!",10,13
	dc.b	0
	even
txt_boot_err:
	dc.b	"Cannot read the boot sector!",10,13
	dc.b	0
	even
txt_exec_err:
	dc.b	"Failed to rip the cracktro!",10,13
	dc.b	0
	even
txt_nofile:
	dc.b	"No boot-cracktro or files!",10,13
	dc.b	0
	even
txt_read_err:
	dc.b	"Failed to read the file!",10,13
	dc.b	0
	even
txt_fexist_err:
	dc.b	"Destination file already exists!",10,13
	dc.b	0
	even
txt_write_err:
	dc.b	"Failed to write the file!",10,13
	dc.b	0
	even
txt_fatal_exit:
	dc.b	"Press any key to exit",10,13
	dc.b	0
	even
txt_title:
	dc.b	27,"E",27,"Y",32,32
	dc.b	27,"p","  BOOT-CRACKTRO R1PP3R v1.0  ",10,13
	dc.b	       "  by Orion / The Replicants  ",27,"q",10,13
	dc.b	0
	even

KEY_RIP     =	'1'
KEY_HELP    =	'2'
KEY_CREDITS =	'3'
KEY_GREETS  =	'4'
KEY_EXIT    =	'5'
KEY_ANALYZE =	'6'
KEY_TESTS   =	'6'+DBG_BOOT_ANALYSIS

txt_main:
	dc.b	10,13
	dc.b	27,"p"," ",KEY_RIP,    " ",27,"q","   Rip a boot-cracktro",10,13
	dc.b	27,"p"," ",KEY_HELP,   " ",27,"q","   Help",10,13
	dc.b	27,"p"," ",KEY_CREDITS," ",27,"q","   Credits",10,13
	dc.b	27,"p"," ",KEY_GREETS, " ",27,"q","   Greetings",10,13
	dc.b	27,"p"," ",KEY_EXIT,   " ",27,"q","   Exit",10,13
	ifne	DBG_BOOT_ANALYSIS
	dc.b	27,"p"," ",KEY_ANALYZE," ",27,"q","   Boot analysis  [Debug]",10,13
	endc	; DBG_BOOT_ANALYSIS
	ifne	DBG_SELFTESTS
	dc.b	27,"p"," ",KEY_TESTS,  " ",27,"q","   Selftests      [Debug]",10,13
	endc	; DBG_SELFTESTS
	dc.b	0
	even
txt_help:
	dc.b	10,13
	dc.b	"This program rips cracktros that are not",10,13
	dc.b	"in file form.  Some  games do  not use a",10,13
	dc.b	"file  system and  load their  data  from",10,13
	dc.b	"hard-coded areas of the disk without TOS",10,13
	dc.b	"support.  The  cracktros  used on  these",10,13
	dc.b	"games  are also stored  directly on disk",10,13
	dc.b	"sectors.  This  program  allows  you  to",10,13
	dc.b	"extract such a cracktro in order to save",10,13
	dc.b	"it as a standard PRG that is  executable",10,13
	dc.b	"from  the GEM.  This  program  has  been",10,13
	dc.b	"developed  to help  the archivists (such",10,13
	dc.b	"as  demozoo)  in their work  of indexing",10,13
	dc.b	"and preserving Atari ST cracktros.      ",10,13
	dc.b	10,13
	dc.b	"Select the first option of the main menu",10,13
	dc.b	"and simply follow the instructions.     ",10,13
	dc.b	10,13
	dc.b	0
	even
txt_credits:
	dc.b	10,13
	dc.b	"Release date: March 2021                ",10,13
	dc.b	"Source: https://github.com/orionfuzion  ",10,13
	dc.b	"Contact: orion.replicants@gmail.com     ",10,13
	dc.b	10,13
	dc.b	0
	even
txt_greetings:
	dc.b	10,13
	dc.b	"Mega greetings to the  archivists of the",10,13
	dc.b	"Atari ST scene and preservation experts:",10,13
	dc.b	10,13
	dc.b	"Lotek Style / tSCc    Brume / AL        ",10,13
	dc.b	"Marcer / Elite        Mug UK / AL       ",10,13
	dc.b	"Grazey / PHF          Maartau / AL      ",10,13
	dc.b	"Spiny / Torment       Tronic / Effect   ",10,13
	dc.b	"Troed / SYNC          Bandit / Climatics",10,13
	dc.b	"Lowlife / Elite       Skinhead / ICS    ",10,13
	dc.b	"DrCoolZic             ijor              ",10,13
	dc.b	"Marakatti             Kodak80           ",10,13
	dc.b	"Mikerochip            Requiem           ",10,13
	dc.b	"GreatGuy              Jim               ",10,13
	dc.b	"dlfrsilver            Mia Jaap          ",10,13
	dc.b	10,13
	dc.b	"and all the sceners  who are  helping to",10,13
	dc.b	"preserve the Atari ST heritage.         ",10,13
	dc.b	10,13
	dc.b	0
	even
txt_rip_start:
	dc.b	"Insert the disk in drive A",10,13
	dc.b	"Then press any key to start",10,13
	dc.b	0
	even
txt_file_load_select:
	dc.b	"The disk contains regular files!",10,13
	dc.b	"Select the cracktro file to be copied",10,13
	dc.b	0
	even
txt_file_load:
	dc.b	"Loading the file, please wait...",10,13
	dc.b	0
	even
txt_boot_save_select:
	dc.b	"Cracktro ripped and ready to be saved!",10,13
	dc.b	0
	even
txt_file_save_select:
	dc.b	"File loaded and ready to be saved!",10,13
	dc.b	0
	even
txt_save_change_disk:
	dc.b	"Insert the destination disk in drive A",10,13
	dc.b	"Then press any key to start",10,13
	dc.b	0
	even
txt_save_select:
	dc.b	"Choose an unused destination filename",10,13
	dc.b	0
	even
txt_file_save:
	dc.b	"Saving the file, please wait...",10,13
	dc.b	0
	even
txt_file_save_success:
	dc.b	"File saved successfully!",10,13
	dc.b	0
	even
txt_file_cancel:
	dc.b	"Operation cancelled!",10,13
	dc.b	0
	even
txt_return_main:
	dc.b	"Hit any key to return to the main menu",10,13
	dc.b	0
	even

	section	bss

	; Buffer for loading the bootsector.
bootsector_buf:
	ds.b	512
	; Temporary buffer for loading root directory sectors.
sector_buf:
	ds.b	512

	; Program stack.
stack_bottom:
	ds.b	STACK_SIZE
stack_top:
	even

	; The preamble code is copied here, right before the buffer
	; where the ripped cracktro is saved.
intro_header_dest:
	ds.b	(intro_preamble_end-intro_header)
	; The ripped cracktro is saved here.
intro_buf:
	; End of the program.
pt_end:
	end
