!
!	setup.s		(C) 1991 Linus Torvalds
!
! setup.s is responsible for getting the system data from the BIOS,
! and putting them into the appropriate places in system memory.
! both setup.s and system has been loaded by the bootblock.
!
! This code asks the bios for memory/disk/other parameters, and
! puts them in a "safe" place: 0x90000-0x901FF, ie where the
! boot-block used to be. It is then up to the protected mode
! system to read them from there before the area is overwritten
! for buffer-blocks.
!

! NOTE! These had better be the same as in bootsect.s!
#include <linux/config.h>

INITSEG  = DEF_INITSEG	! we move boot here - out of the way, 0x9000
SYSSEG   = DEF_SYSSEG	! system loaded at 0x10000 (65536). 0x1000
SETUPSEG = DEF_SETUPSEG	! this is the current segment, 0x9020

.globl begtext, begdata, begbss, endtext, enddata, endbss
.text
begtext:
.data
begdata:
.bss
begbss:
.text

entry start
start:

! ok, the read went well so we get current cursor position and save it for
! posterity.
	! 数据段寄存器的段值设置为0x9000
	mov	ax,#INITSEG	! this is done in bootsect already, but...
	mov	ds,ax

! Get memory size (extended mem, kB)
	! TODO, BIOS的0x15号中断, 功能号0x88取系统所含扩展内存大小
	! 返回: ax=从0x100000(1M)处开始的扩展内存大小(KB), 若出错
	! 则CF置位, ax=出错码.
	mov	ah,#0x88
	int	0x15
	mov	[2],ax		! 扩展内存的大小放在0x9000:2处

! check for EGA/VGA and some config parameters
	! 检查显示方式(EGA/VGA)并取参数.
	! TODO, BIOS的0x10号中断, 功能号0x12, bl=0x10
	! 返回: bh=显示状态, cx=显示卡特性参数
	mov	ah,#0x12
	mov	bl,#0x10
	int	0x10
	mov	[8],ax
	mov	[10],bx		! 0x9000A存放安装的显示内存,0x9000B存放显示状态
	mov	[12],cx		! 0x9000C存放显示卡特性参数
	mov	ax,#0x5019	! 在ax中预置屏幕默认的行列值(ah=0x50即80列, al=0x19即25行)
	cmp	bl,#0x10	! 若中断返回bl值为0x10,则表示不是VGA显卡，是的话会返回显存大小
	je	novga
	call	chsvga		! 是VGA显卡,检测显示卡厂家和类型，修改显示行列值
novga:	mov	[14],ax		! 0x9000E,0x9000F分别存放屏幕当前的行列值(0x5019)
	! TODO,利用BIOS的0x10号中断,功能号0x03，
	! 返回: ch=扫描开始线,cl=扫描结束线；dh=行号，dl=列号(0x00为最左边)
	mov	ah,#0x03	! read cursor pos
	xor	bh,bh
	int	0x10		! save it in known place, con_init fetches
	mov	[0],dx		! it from 0x90000.
	
! Get video-card data:
	
	mov	ah,#0x0f
	int	0x10
	mov	[4],bx		! bh = display page, 0x90004存放当前页
	mov	[6],ax		! al = video mode, ah = window width, 0x90006存放显示模式, 0x90007存放字符列数

! Get hd0 data
	! 取第一个硬盘的参数值(复制硬盘参数表)
	! 第一个硬盘参数表的首地址是中断向量0x41的向量值, 第二个硬盘参数表紧接在第一个表的后面.
	! 表长度为16个字节
	mov	ax,#0x0000
	mov	ds,ax
	lds	si,[4*0x41]	! 取中断向量0x41的值, 即hd0参数表的地址到ds:si
	mov	ax,#INITSEG
	mov	es,ax
	mov	di,#0x0080
	mov	cx,#0x10
	! ds:si存放了0x0:0x41*4处的内容，即hd0的参数表首地址, 目的地es:di为0x9000:0x0080，共传送0x10即16字节
	rep
	movsb

! Get hd1 data

	mov	ax,#0x0000
	mov	ds,ax
	lds	si,[4*0x46]	! 取中断向量0x46的值, 即hd1参数表的地址到ds:si
	mov	ax,#INITSEG
	mov	es,ax
	mov	di,#0x0090
	mov	cx,#0x10
	! ds:si存放了0x0:0x46*4处的内容，即hd1的参数表首地址, 目的地es:di为0x9000:0x0090，共传送0x10即16字节
	rep
	movsb

! Check that there IS a hd1 :-)
	! TODO, 检查系统是否有第2个硬盘
	! 利用BIOS中断0x13，功能号0x15，取盘类型功能
	! 输入: dl=驱动器号(0x8x是硬盘, 0x80指第一个硬盘, 0x81指第二个硬盘)
	! 输出: ah=类型码: 00代表没有这个盘, CF置位; 01代表是软驱, 没有change-line支持;
	!		   02代表是软驱(或其他可移动设备), 有change-line支持; 03代表硬盘
	mov	ax,#0x01500
	mov	dl,#0x81
	int	0x13
	jc	no_disk1	! CF置位表示没有这个盘
	cmp	ah,#3
	je	is_disk1
no_disk1:
	mov	ax,#INITSEG
	mov	es,ax
	mov	di,#0x0090
	mov	cx,#0x10
	mov	ax,#0x00
	! stosb把ax(0x0)的内容填充到es:di(0x9000:0090)处，共填充16字节, 即把hd1的参数表值清零
	rep
	stosb
is_disk1:

! now we want to move to protected mode ...
	! 准备进入保护模式, 从此开始不允许中断
	cli			! no interrupts allowed !

! first we move the system to it's rightful place
	! bootsect会把system模块读到0x10000(64K)处，由于当时假设system模块最大长度不会超过0x80000(512KB)
	! 即末端不会超过内存地址0x90000，所以bootsect会把自己移动到0x90000开始的地方，并把setup加载在他
	! 后面.
	mov	ax,#0x0000
	cld			! 'direction'=0, movs moves forward
do_move:
	mov	es,ax		! destination segment
	add	ax,#0x1000	! 每移动64KB后ax在此都会加0x1000，当移动了8次之后就跳到end_move了
	cmp	ax,#0x9000
	jz	end_move
	mov	ds,ax		! source segment
	sub	di,di
	sub	si,si
	mov 	cx,#0x8000
	! 将ds:si(0x1000:0)处内容移动到es:di(0x0:0)处, 每次共移动0x8000*2个字节(64KB)
	rep
	movsw
	jmp	do_move

! then we load the segment descriptors

end_move:
	mov	ax,#SETUPSEG	! right, forgot this at first. didn't work :-)
	mov	ds,ax		! ds指向本程序(setup)段
				! idtr和gdtr的0-15位是Limit, 16-47位为Base Address
	lidt	idt_48		! load idt with 0,0, 加载idtr寄存器
				! idt_48定义为0,0
				!  .word   0   ! idt limit=0
				!  .word   0,0 ! idt base=0L
	lgdt	gdt_48		! load gdt with whatever appropriate, 加载gdtr寄存器, gtd_48定义为
				! gdt_48:
				!  .word   0x800       ! gdt limit=2048, 256 GDT entries
				!		       ! 每个gdt全局描述符表项大小为8个字节
				!  .word   512+gdt,0x9 ! gdt base = 0X9xxxx
				!                      ! 0x9<<4 + (512+gdt)因为setup在bootsect之后
				!		       ! bootsect为512字节, 所以这里要加上512
! that was painless, now we enable A20
! 为了能够访问1MB以上的物理内存，需要首先打开A20地址线
	call	empty_8042		! 测试8042状态寄存器，等待输入缓冲器空.
					! 只有在输入缓冲器空时才可以对其执行写命令.
	mov	al,#0xD1		! command write, 0xD1命令码，表示要写数据到8042的P2端口.P2端口位1用于A20线选通
	out	#0x64,al
	call	empty_8042		! 等待输入缓冲器空，看命令是否被接受
	mov	al,#0xDF		! A20 on，打开A20地址线
	out	#0x60,al		! 数据写到0x60端口.
	call	empty_8042		! 若此时输入缓冲器为空, 则表示A20线已经选通

! well, that went ok, I hope. Now we have to reprogram the interrupts :-(
! we put them right after the intel-reserved hardware interrupts, at
! int 0x20-0x2F. There they won't mess up anything. Sadly IBM really
! messed this up with the original PC, and they haven't been able to
! rectify it afterwards. Thus the bios puts interrupts at 0x08-0x0f,
! which is used for the internal hardware interrupts as well. We just
! have to reprogram the 8259's, and it isn't fun.
! 0x00eb是近跳转的机器码，可以提供7-10个时钟周期数
! 8259芯片主片端口是0x20-0x21，从片端口是0xA0-0xA1. 输出值0x11表示初始化命令开始
	mov	al,#0x11		! initialization sequence
	out	#0x20,al		! send it to 8259A-1
	.word	0x00eb,0x00eb		! jmp $+2, jmp $+2
	out	#0xA0,al		! and to 8259A-2
	.word	0x00eb,0x00eb
	mov	al,#0x20		! start of hardware int's (0x20)
	out	#0x21,al		! 主8259a的irq0对应于0x20(irq32)
	.word	0x00eb,0x00eb
	mov	al,#0x28		! start of hardware int's 2 (0x28)
	out	#0xA1,al		! 从8259a的irq0对应于0x28(irq40)
	.word	0x00eb,0x00eb
	mov	al,#0x04		! 8259-1 is master
	out	#0x21,al		! IR2级联从片
	.word	0x00eb,0x00eb
	mov	al,#0x02		! 8259-2 is slave
	out	#0xA1,al		! 从片连的主片的IR号(IR2)
	.word	0x00eb,0x00eb
	mov	al,#0x01		! 8086 mode for both
	out	#0x21,al		! 80x86模式
	.word	0x00eb,0x00eb
	out	#0xA1,al		! 80x86模式
	.word	0x00eb,0x00eb
	mov	al,#0xFF		! mask off all interrupts for now
	out	#0x21,al		! 屏蔽主芯片所有中断请求
	.word	0x00eb,0x00eb
	out	#0xA1,al		! 屏蔽从芯片所有中断请求

! well, that certainly wasn't fun :-(. Hopefully it works, and we don't
! need no steenking BIOS anyway (except for the initial loading :-).
! The BIOS-routine wants lots of unnecessary data, and it's less
! "interesting" anyway. This is how REAL programmers do it.
!
! Well, now's the time to actually move into protected mode. To make
! things as simple as possible, we do no register set-up or anything,
! we let the gnu-compiled 32-bit programs do that. We just jump to
! absolute address 0x00000, in 32-bit protected mode.
! lmsw用于加载机器状态字,也称为控制寄存器CR0，位0置1(PE位)将导致CPU切换到保护模式,
! 并且处于特权级0中，即当前的CPL=0，此时段寄存器仍然指向与实地址模式中相同的线性地
! 址处(实模式下线性地址与物理地址相同). 设置该位后，随后的一条指令必须是一条段间跳转
! 指令用于刷新CPU当前的指令队列.因为CPU是在执行一条指令之前就已经从内存读取该指令并
! 对其进行解码. 然后在进入保护模式以后那些属于实模式的预先取得的指令信息就变得不再有效.
! 而一条段间跳转指令就会刷新CPU当前的指令队列，即丢弃这些无效的信息. 另外, 在Intel公司手册
! 上建议80386或以上CPU应该使用指令"mov cr0, ax"切换到保护模式.lmsw指令仅用于兼容以前的286CPU
	mov	ax,#0x0001	! protected mode (PE) bit
	lmsw	ax		! This is it!

! 选择子图示:
!  |15                         3| 2  | 1  0|
!  -----------------------------------------
!  |       描述符号索引         | TI | RPL |
!  -----------------------------------------
! RPL(Requested Privilege Level): 请求特权级，用于特权检查。
!
! TI(Table Indicator): 引用描述符表指示位
!       TI=0 指示从全局描述符表GDT中读取描述符;
!       TI=1 指示从局部描述符表LDT中读取描述符.
!

	jmpi	0,8		! jmp offset 0 of segment 8 (cs)

! This routine checks that the keyboard command queue is empty
! No timeout is used - if this hangs there is something wrong with
! the machine, and we probably couldn't proceed anyway.
empty_8042:
	.word	0x00eb,0x00eb
	in	al,#0x64	! 8042 status port
	test	al,#2		! is input buffer full?
	jnz	empty_8042	! yes - loop
	ret

! Routine trying to recognize type of SVGA-board present (if any)
! and if it recognize one gives the choices of resolution it offers.
! If one is found the resolution chosen is given by al,ah (rows,cols).

chsvga:	cld
	push	ds
	push	cs
	pop	ds
	mov 	ax,#0xc000
	mov	es,ax
	lea	si,msg1
	call	prtstr
nokey:	in	al,#0x60
	cmp	al,#0x82
	jb	nokey
	cmp	al,#0xe0
	ja	nokey
	cmp	al,#0x9c
	je	svga
	mov	ax,#0x5019
	pop	ds
	ret
svga:	lea 	si,idati		! Check ATI 'clues'
	mov	di,#0x31
	mov 	cx,#0x09
	repe
	cmpsb
	jne	noati
	lea	si,dscati
	lea	di,moati
	lea	cx,selmod
	jmp	cx
noati:	mov	ax,#0x200f		! Check Ahead 'clues'
	mov	dx,#0x3ce
	out	dx,ax
	inc	dx
	in	al,dx
	cmp	al,#0x20
	je	isahed
	cmp	al,#0x21
	jne	noahed
isahed:	lea	si,dscahead
	lea	di,moahead
	lea	cx,selmod
	jmp	cx
noahed:	mov	dx,#0x3c3		! Check Chips & Tech. 'clues'
	in	al,dx
	or	al,#0x10
	out	dx,al
	mov	dx,#0x104		
	in	al,dx
	mov	bl,al
	mov	dx,#0x3c3
	in	al,dx
	and	al,#0xef
	out	dx,al
	cmp	bl,[idcandt]
	jne	nocant
	lea	si,dsccandt
	lea	di,mocandt
	lea	cx,selmod
	jmp	cx
nocant:	mov	dx,#0x3d4		! Check Cirrus 'clues'
	mov	al,#0x0c
	out	dx,al
	inc	dx
	in	al,dx
	mov	bl,al
	xor	al,al
	out	dx,al
	dec	dx
	mov	al,#0x1f
	out	dx,al
	inc	dx
	in	al,dx
	mov	bh,al
	xor	ah,ah
	shl	al,#4
	mov	cx,ax
	mov	al,bh
	shr	al,#4
	add	cx,ax
	shl	cx,#8
	add	cx,#6
	mov	ax,cx
	mov	dx,#0x3c4
	out	dx,ax
	inc	dx
	in	al,dx
	and	al,al
	jnz	nocirr
	mov	al,bh
	out	dx,al
	in	al,dx
	cmp	al,#0x01
	jne	nocirr
	call	rst3d4	
	lea	si,dsccirrus
	lea	di,mocirrus
	lea	cx,selmod
	jmp	cx
rst3d4:	mov	dx,#0x3d4
	mov	al,bl
	xor	ah,ah
	shl	ax,#8
	add	ax,#0x0c
	out	dx,ax
	ret	
nocirr:	call	rst3d4			! Check Everex 'clues'
	mov	ax,#0x7000
	xor	bx,bx
	int	0x10
	cmp	al,#0x70
	jne	noevrx
	shr	dx,#4
	cmp	dx,#0x678
	je	istrid
	cmp	dx,#0x236
	je	istrid
	lea	si,dsceverex
	lea	di,moeverex
	lea	cx,selmod
	jmp	cx
istrid:	lea	cx,ev2tri
	jmp	cx
noevrx:	lea	si,idgenoa		! Check Genoa 'clues'
	xor 	ax,ax
	seg es
	mov	al,[0x37]
	mov	di,ax
	mov	cx,#0x04
	dec	si
	dec	di
l1:	inc	si
	inc	di
	mov	al,(si)
	seg es
	and	al,(di)
	cmp	al,(si)
	loope 	l1
	cmp	cx,#0x00
	jne	nogen
	lea	si,dscgenoa
	lea	di,mogenoa
	lea	cx,selmod
	jmp	cx
nogen:	lea	si,idparadise		! Check Paradise 'clues'
	mov	di,#0x7d
	mov	cx,#0x04
	repe
	cmpsb
	jne	nopara
	lea	si,dscparadise
	lea	di,moparadise
	lea	cx,selmod
	jmp	cx
nopara:	mov	dx,#0x3c4		! Check Trident 'clues'
	mov	al,#0x0e
	out	dx,al
	inc	dx
	in	al,dx
	xchg	ah,al
	mov	al,#0x00
	out	dx,al
	in	al,dx
	xchg	al,ah
	mov	bl,al		! Strange thing ... in the book this wasn't
	and	bl,#0x02	! necessary but it worked on my card which
	jz	setb2		! is a trident. Without it the screen goes
	and	al,#0xfd	! blurred ...
	jmp	clrb2		!
setb2:	or	al,#0x02	!
clrb2:	out	dx,al
	and	ah,#0x0f
	cmp	ah,#0x02
	jne	notrid
ev2tri:	lea	si,dsctrident
	lea	di,motrident
	lea	cx,selmod
	jmp	cx
notrid:	mov	dx,#0x3cd		! Check Tseng 'clues'
	in	al,dx			! Could things be this simple ! :-)
	mov	bl,al
	mov	al,#0x55
	out	dx,al
	in	al,dx
	mov	ah,al
	mov	al,bl
	out	dx,al
	cmp	ah,#0x55
 	jne	notsen
	lea	si,dsctseng
	lea	di,motseng
	lea	cx,selmod
	jmp	cx
notsen:	mov	dx,#0x3cc		! Check Video7 'clues'
	in	al,dx
	mov	dx,#0x3b4
	and	al,#0x01
	jz	even7
	mov	dx,#0x3d4
even7:	mov	al,#0x0c
	out	dx,al
	inc	dx
	in	al,dx
	mov	bl,al
	mov	al,#0x55
	out	dx,al
	in	al,dx
	dec	dx
	mov	al,#0x1f
	out	dx,al
	inc	dx
	in	al,dx
	mov	bh,al
	dec	dx
	mov	al,#0x0c
	out	dx,al
	inc	dx
	mov	al,bl
	out	dx,al
	mov	al,#0x55
	xor	al,#0xea
	cmp	al,bh
	jne	novid7
	lea	si,dscvideo7
	lea	di,movideo7
selmod:	push	si
	lea	si,msg2
	call	prtstr
	xor	cx,cx
	mov	cl,(di)
	pop	si
	push	si
	push	cx
tbl:	pop	bx
	push	bx
	mov	al,bl
	sub	al,cl
	call	dprnt
	call	spcing
	lodsw
	xchg	al,ah
	call	dprnt
	xchg	ah,al
	push	ax
	mov	al,#0x78
	call	prnt1
	pop	ax
	call	dprnt
	call	docr
	loop	tbl
	pop	cx
	call	docr
	lea	si,msg3
	call	prtstr
	pop	si
	add	cl,#0x80
nonum:	in	al,#0x60	! Quick and dirty...
	cmp	al,#0x82
	jb	nonum
	cmp	al,#0x8b
	je	zero
	cmp	al,cl
	ja	nonum
	jmp	nozero
zero:	sub	al,#0x0a
nozero:	sub	al,#0x80
	dec	al
	xor	ah,ah
	add	di,ax
	inc	di
	push	ax
	mov	al,(di)
	int 	0x10
	pop	ax
	shl	ax,#1
	add	si,ax
	lodsw
	pop	ds
	ret
novid7:	pop	ds	! Here could be code to support standard 80x50,80x30
	mov	ax,#0x5019	
	ret

! Routine that 'tabs' to next col.

spcing:	mov	al,#0x2e
	call	prnt1
	mov	al,#0x20
	call	prnt1	
	mov	al,#0x20
	call	prnt1	
	mov	al,#0x20
	call	prnt1	
	mov	al,#0x20
	call	prnt1
	ret	

! Routine to print asciiz-string at DS:SI

prtstr:	lodsb
	and	al,al
	jz	fin
	call	prnt1
	jmp	prtstr
fin:	ret

! Routine to print a decimal value on screen, the value to be
! printed is put in al (i.e 0-255). 

dprnt:	push	ax
	push	cx
	mov	ah,#0x00		
	mov	cl,#0x0a
	idiv	cl
	cmp	al,#0x09
	jbe	lt100
	call	dprnt
	jmp	skip10
lt100:	add	al,#0x30
	call	prnt1
skip10:	mov	al,ah
	add	al,#0x30
	call	prnt1	
	pop	cx
	pop	ax
	ret

! Part of above routine, this one just prints ascii al

prnt1:	push	ax
	push	cx
	mov	bh,#0x00
	mov	cx,#0x01
	mov	ah,#0x0e
	int	0x10
	pop	cx
	pop	ax
	ret

! Prints <CR> + <LF>

docr:	push	ax
	push	cx
	mov	bh,#0x00
	mov	ah,#0x0e
	mov	al,#0x0a
	mov	cx,#0x01
	int	0x10
	mov	al,#0x0d
	int	0x10
	pop	cx
	pop	ax
	ret	
! 数据段描述符
! |31          24| 23| 22| 21| 20|19    16| 15|14 13| 12|11            8|7              0|
! ----------------------------------------------------------------------------------------
! |     基地址   |   |   |   | A | 段限长 |   |     |   |      TYPE     |     基地址     |
! |              | G | B | 0 | V |        | P | DPL | 1 |               |        	 |
! |  Base 31..24 |   |   |   | L | 19..16 |   |     |   | 0 | E | W | A |  Base 23..16   |
! ----------------------------------------------------------------------------------------
! |              基地址                   |               段限长                         |
! |                                       |                                              |
! |         Base Address 15..0            |         Segment Limit 15..0                  |
! ----------------------------------------------------------------------------------------
!
! 代码段描述符
! |31          24| 23| 22| 21| 20|19    16| 15|14 13| 12|11            8|7              0|
! ----------------------------------------------------------------------------------------
! |     基地址   |   |   |   | A | 段限长 |   |     |   |      TYPE     |     基地址     |
! |              | G | B | 0 | V |        | P | DPL | 1 |               |        	 |
! |  Base 31..24 |   |   |   | L | 19..16 |   |     |   | 1 | C | R | A |  Base 23..16   |
! ----------------------------------------------------------------------------------------
! |              基地址                   |               段限长                         |
! |                                       |                                              |
! |         Base Address 15..0            |         Segment Limit 15..0                  |
! ----------------------------------------------------------------------------------------
!
!  说明:
!
! (1) P:    存在(Present)位。
!               P=1 表示描述符对地址转换是有效的，或者说该描述符所描述的段存在，即在内存中；
!               P=0 表示描述符对地址转换无效，即该段不存在。使用该描述符进行内存访问时会引起异常。
!
! (2) DPL:  表示描述符特权级(Descriptor Privilege level)，共2位。它规定了所描述段的特权级，用于特权检查，以决定对该段>能否访问。
!
! (3) S:   说明描述符的类型。
!               对于存储段描述符而言，S=1，以区别与系统段描述符和门描述符(S=0)。
!
! (4) TYPE: 说明存储段描述符所描述的存储段的具体属性。
!
!       数据段类型      类型值          说明
!                       ----------------------------------
!                       0               只读
!                       1               只读、已访问
!                       2               读/写
!                       3               读/写、已访问
!                       4               只读、向下扩展
!                       5               只读、向下扩展、已访问
!                       6               读/写、向下扩展
!                       7               读/写、向下扩展、已访问
!
!                       类型值          说明
!       代码段类型      ----------------------------------
!                       8               只执行
!                       9               只执行、已访问
!                       A               执行/读
!                       B               执行/读、已访问
!                       C               只执行、一致码段
!                       D               只执行、一致码段、已访问
!                       E               执行/读、一致码段
!                       F               执行/读、一致码段、已访问
!       系统段类型      类型编码        说明
!                       ----------------------------------
!                       0               <未定义>
!                       1               可用286TSS
!                       2               LDT
!                       3               忙的286TSS
!                       4               286调用门
!                       5               任务门
!                       6               286中断门
!                       7               286陷阱门
!                       8               未定义
!                       9               可用386TSS
!                       A               <未定义>
!                       B               忙的386TSS
!                       C               386调用门
!                       D               <未定义>
!                       E               386中断门
!                       F               386陷阱门
!
! (5) G:    段界限粒度(Granularity)位。
!               G=0 表示界限粒度为字节；
!               G=1 表示界限粒度为4K 字节。
!           注意，界限粒度只对段界限有效，对段基地址无效，段基地址总是以字节为单位。
!
! (6) D:    D位是一个很特殊的位，在描述可执行段、向下扩展数据段或由SS寄存器寻址的段(通常是堆栈段)的三种描述符中的意义>各不相同。
!           (1) 在描述可执行段的描述符中，D位决定了指令使用的地址及操作数所默认的大小。
!               ① D=1表示默认情况下指令使用32位地址及32位或8位操作数，这样的代码段也称为32位代码段；
!               ② D=0 表示默认情况下，使用16位地址及16位或8位操作数，这样的代码段也称为16位代码段，它与80286兼容。可以使用地址大
!                 小前缀和操作数大小前缀分别改变默认的地址或操作数的大小。
!           (2) 在向下扩展数据段的描述符中，D位决定段的上部边界。
!               ① D=1表示段的上部界限为4G；
!               ② D=0表示段的上部界限为64K，这是为了与80286兼容。
!           (3 )在描述由SS寄存器寻址的段描述符中，D位决定隐式的堆栈访问指令(如PUSH和POP指令)使用何种堆栈指针寄存器。
!               ① D=1表示使用32位堆栈指针寄存器ESP；
!               ② D=0表示使用16位堆栈指针寄存器SP，这与80286兼容。
!
! (7) AVL:  软件可利用位。80386对该位的使用未左规定，Intel公司也保证今后开发生产的处理器只要与80386兼容，就不会对该位的使用做任何定义或规定。
!
gdt:
	.word	0,0,0,0		! dummy

	.word	0x07FF		! 8Mb - limit=2047 (2048*4096=8Mb)
	.word	0x0000		! base address=0
	.word	0x9A00		! code read/exec
	.word	0x00C0		! granularity=4096, 386

	.word	0x07FF		! 8Mb - limit=2047 (2048*4096=8Mb)
	.word	0x0000		! base address=0
	.word	0x9200		! data read/write
	.word	0x00C0		! granularity=4096, 386

idt_48:
	.word	0			! idt limit=0
	.word	0,0			! idt base=0L

gdt_48:
	.word	0x800		! gdt limit=2048, 256 GDT entries
	.word	512+gdt,0x9	! gdt base = 0X9xxxx

msg1:		.ascii	"Press <RETURN> to see SVGA-modes available or any other key to continue."
		db	0x0d, 0x0a, 0x0a, 0x00
msg2:		.ascii	"Mode:  COLSxROWS:"
		db	0x0d, 0x0a, 0x0a, 0x00
msg3:		.ascii	"Choose mode by pressing the corresponding number."
		db	0x0d, 0x0a, 0x00
		
idati:		.ascii	"761295520"
idcandt:	.byte	0xa5
idgenoa:	.byte	0x77, 0x00, 0x66, 0x99
idparadise:	.ascii	"VGA="

! Manufacturer:	  Numofmodes:	Mode:

moati:		.byte	0x02,	0x23, 0x33 
moahead:	.byte	0x05,	0x22, 0x23, 0x24, 0x2f, 0x34
mocandt:	.byte	0x02,	0x60, 0x61
mocirrus:	.byte	0x04,	0x1f, 0x20, 0x22, 0x31
moeverex:	.byte	0x0a,	0x03, 0x04, 0x07, 0x08, 0x0a, 0x0b, 0x16, 0x18, 0x21, 0x40
mogenoa:	.byte	0x0a,	0x58, 0x5a, 0x60, 0x61, 0x62, 0x63, 0x64, 0x72, 0x74, 0x78
moparadise:	.byte	0x02,	0x55, 0x54
motrident:	.byte	0x07,	0x50, 0x51, 0x52, 0x57, 0x58, 0x59, 0x5a
motseng:	.byte	0x05,	0x26, 0x2a, 0x23, 0x24, 0x22
movideo7:	.byte	0x06,	0x40, 0x43, 0x44, 0x41, 0x42, 0x45

!			msb = Cols lsb = Rows:

dscati:		.word	0x8419, 0x842c
dscahead:	.word	0x842c, 0x8419, 0x841c, 0xa032, 0x5042
dsccandt:	.word	0x8419, 0x8432
dsccirrus:	.word	0x8419, 0x842c, 0x841e, 0x6425
dsceverex:	.word	0x5022, 0x503c, 0x642b, 0x644b, 0x8419, 0x842c, 0x501e, 0x641b, 0xa040, 0x841e
dscgenoa:	.word	0x5020, 0x642a, 0x8419, 0x841d, 0x8420, 0x842c, 0x843c, 0x503c, 0x5042, 0x644b
dscparadise:	.word	0x8419, 0x842b
dsctrident:	.word 	0x501e, 0x502b, 0x503c, 0x8419, 0x841e, 0x842b, 0x843c
dsctseng:	.word	0x503c, 0x6428, 0x8419, 0x841c, 0x842c
dscvideo7:	.word	0x502b, 0x503c, 0x643c, 0x8419, 0x842c, 0x841c
	
.text
endtext:
.data
enddata:
.bss
endbss:
