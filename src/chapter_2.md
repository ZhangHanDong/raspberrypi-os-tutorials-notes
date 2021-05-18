# 运行环境（Runtime）初始化

为了后面进一步在裸机上运行 Rust 程序，以及编写真正的驱动程序，我们需要做一些准备工作：初始化运行环境（Runtime）。以往我们编程，很多工作都由操作系统来完成了，比如运行环境初始化。但别忘记我们现在面对的是裸机（Bare Matel）。比如 C 语言，它的运行时系统被称为 CRT（C-Runtime）。

而 Rust 语言，在链接标准库的情况下，首先会跳到 C 语言运行时环境中的 crt0（C Runtime Zero）进入 C 语言运行时环境设置 C 程序运行所需要的环境（如创建堆栈或设置寄存器参数等）。

然后 C 语言运行时环境会跳转到 Rust 运行时环境的入口点（Entry Point）进入 Rust 运行时入口函数继续设置 Rust 运行环境，而这个 Rust 的运行时入口点就是被 start 语义项标记的。Rust 运行时环境的入口点结束之后才会调用 main 函数进入主程序。

所以，main 函数并不是实际执行的第一个函数。

但是，目前我们在写 嵌入式，使用 no-std 环境，所以我们先用一个 `_start` 来作为 入口点，创建好 Rust 代码执行所需要的环境，再调用 Rust 代码。

## 树莓派3 的相关配置

在 `docker/rustembedded-osdev-utils/rpi3.cfg` 中，有一段关键配置需要先了解：

```text
set DBGBASE {0x80010000 0x80012000 0x80014000 0x80016000}
set CTIBASE {0x80018000 0x80019000 0x8001a000 0x8001b000}
set _cores 4

for { set _core 0 } { $_core < $_cores } { incr _core } {

    cti create $_CTINAME.$_core -dap $_CHIPNAME.dap -ap-num 0 \
        -ctibase [lindex $CTIBASE $_core]

    target create $_TARGETNAME$_core aarch64 \
        -dap $_CHIPNAME.dap -coreid $_core \
        -dbgbase [lindex $DBGBASE $_core] -cti $_CTINAME.$_core

    $_TARGETNAME$_core configure -event reset-assert-post "aarch64 dbginit"
    $_TARGETNAME$_core configure -event gdb-attach { halt }
}
```

上面 `set DBGBASE` 和 `set CTIBASE`，是用于 OpenOCD/GDB 使用。

> OpenOCD 提供了GDB Server，可以通过它进行GDB相关的调试操作

`set _cores 4` 是设置树莓派3 为 四个核心，下面的 for 循环用于为四个核进行 GDB 调试相关设置。

所以这意味着我们处于一个多核（四核）的执行环境。


## 代码解释

先来看看 `boot.s`。 

```rust
//--------------------------------------------------------------------------------------------------
// Definitions
//--------------------------------------------------------------------------------------------------

// Load the address of a symbol into a register, PC-relative.
//
// The symbol must lie within +/- 4 GiB of the Program Counter.
//
// # Resources
//
// - https://sourceware.org/binutils/docs-2.36/as/AArch64_002dRelocations.html
.macro ADR_REL register, symbol
	adrp	\register, \symbol
	add	\register, \register, #:lo12:\symbol
.endm

.equ _core_id_mask, 0b11

//--------------------------------------------------------------------------------------------------
// Public Code
//--------------------------------------------------------------------------------------------------
.section .text._start

//------------------------------------------------------------------------------
// fn _start()
//------------------------------------------------------------------------------
_start:
	// Only proceed on the boot core. Park it otherwise.
	mrs	x1, MPIDR_EL1          // 获取当前代码运行的核
	and	x1, x1, _core_id_mask  // 与 0b11 进行逻辑与计算，总能得到 「0，1，2，3」，对应CPU 四个核的 id
	ldr	x2, BOOT_CORE_ID      // provided by bsp/__board_name__/cpu.rs
	cmp	x1, x2   // 判断是否为 core 0，
	b.ne	1f   // 如果不是 core 0 ，则 跳转 到 标签 1 ，进入待机模式

	// If execution reaches here, it is the boot core. Now, prepare the jump to Rust code.
    // 意味着 core 1/ core 2/ core 3 三个核心都不会到达这里，只有 boot 的 core 0 才能执行 _rust_start

	// Set the stack pointer.
	ADR_REL	x0, __boot_core_stack_end_exclusive // 展开上面定义的 macro 
	mov	sp, x0   // 设置栈指针，为调用 _start_rust 函数做准备

	// Jump to Rust code.
	b	_start_rust

	// Infinitely wait for events (aka "park the core").
1:	wfe
	b	1b

.size	_start, . - _start
.type	_start, function
.global	_start
```

先不管 Rust 代码，看看 qemu 的执行结果：

```text
----------------
IN: 
0x00000300:  d2801b05  mov      x5, #0xd8
0x00000304:  d53800a6  mrs      x6, mpidr_el1
0x00000308:  924004c6  and      x6, x6, #3
0x0000030c:  d503205f  wfe      
0x00000310:  f86678a4  ldr      x4, [x5, x6, lsl #3]
0x00000314:  b4ffffc4  cbz      x4, #0x30c

----------------
IN: 
0x0000030c:  d503205f  wfe      
0x00000310:  f86678a4  ldr      x4, [x5, x6, lsl #3]
0x00000314:  b4ffffc4  cbz      x4, #0x30c

----------------
IN: 
0x00000300:  d2801b05  mov      x5, #0xd8
0x00000304:  d53800a6  mrs      x6, mpidr_el1
0x00000308:  924004c6  and      x6, x6, #3
0x0000030c:  d503205f  wfe      
0x00000310:  f86678a4  ldr      x4, [x5, x6, lsl #3]
0x00000314:  b4ffffc4  cbz      x4, #0x30c

----------------
IN: 
0x00000300:  d2801b05  mov      x5, #0xd8
0x00000304:  d53800a6  mrs      x6, mpidr_el1
0x00000308:  924004c6  and      x6, x6, #3
0x0000030c:  d503205f  wfe      
0x00000310:  f86678a4  ldr      x4, [x5, x6, lsl #3]
0x00000314:  b4ffffc4  cbz      x4, #0x30c

----------------
IN: 
0x00000000:  580000c0  ldr      x0, #0x18
0x00000004:  aa1f03e1  mov      x1, xzr
0x00000008:  aa1f03e2  mov      x2, xzr
0x0000000c:  aa1f03e3  mov      x3, xzr
0x00000010:  58000084  ldr      x4, #0x20
0x00000014:  d61f0080  br       x4

----------------
IN: 
0x00080000:  d53800a1  mrs      x1, mpidr_el1
0x00080004:  92400421  and      x1, x1, #3
0x00080008:  b4000061  cbz      x1, #0x80014

----------------
IN: 
0x00080014:  580000a1  ldr      x1, #0x80028
0x00080018:  9100003f  mov      sp, x1
0x0008001c:  94000005  bl       #0x80030

----------------
IN: 
0x00080030:  90000008  adrp     x8, #0x80000
0x00080034:  90000009  adrp     x9, #0x80000
0x00080038:  91052108  add      x8, x8, #0x148
0x0008003c:  91052129  add      x9, x9, #0x148
0x00080040:  eb08013f  cmp      x9, x8
0x00080044:  54000109  b.ls     #0x80064

----------------
IN: 
0x00080064:  90000009  adrp     x9, #0x80000
0x00080068:  91052129  add      x9, x9, #0x148
0x0008006c:  f800853f  str      xzr, [x9], #8
0x00080070:  eb08013f  cmp      x9, x8
0x00080074:  54ffffc9  b.ls     #0x8006c

----------------
IN: 
0x00080078:  94000008  bl       #0x80098

----------------
IN: 
0x00080098:  90000000  adrp     x0, #0x80000
0x0008009c:  90000002  adrp     x2, #0x80000
0x000800a0:  9102e000  add      x0, x0, #0xb8
0x000800a4:  91032042  add      x2, x2, #0xc8
0x000800a8:  528001c1  mov      w1, #0xe
0x000800ac:  97fffff5  bl       #0x80080

----------------
IN: 
0x00080080:  94000002  bl       #0x80088

----------------
IN: 
0x00080088:  94000002  bl       #0x80090

----------------
IN: 
0x00080090:  d503205f  wfe      
0x00080094:  17ffffff  b        #0x80090
```

上面每个 IN， 基本都可以看作是一个 函数调用栈帧的输出。检查 `adrp` 指令，发现调用了多次，因为 Rust 代码里有几个函数调用。至少我们知道 裸机情况下，多核心可以通过判断 cpuid 来指定做一些事情。通常，多核下，0号核心负责 boot 和执行环境初始化，等到满足一定条件再去唤醒其他核心。

> 你可以尝试下，把 `b.ne 1f` 这行注释掉，把其他三个核心都解放开，看看代码如何执行？

## 链接脚本

一般 `gcc` 进行链接的时候，都会考虑到链接脚本(linker script)，该文件一般以`ld`文件作为后缀名。该文件规定了将特定的section放到文件内，并且控制着输出文件的布局。

我们看 `bsp/raspberrypi/link.ld` 中的代码。

```c
/* The address at which the the kernel binary will be loaded by the Raspberry's firmware */
__rpi_load_addr = 0x80000;

ENTRY(__rpi_load_addr)

PHDRS
{
    segment_rx PT_LOAD FLAGS(5); /* 5 == RX */
    segment_rw PT_LOAD FLAGS(6); /* 6 == RW */
}

SECTIONS
{
    . =  __rpi_load_addr;
                                        /*   ^             */
                                        /*   | stack       */
                                        /*   | growth      */
                                        /*   | direction   */
   __boot_core_stack_end_exclusive = .; /*   |             */

    /***********************************************************************************************
    * Code + RO Data + Global Offset Table
    ***********************************************************************************************/
    .text :
    {
        KEEP(*(.text._start))
        *(.text._start_arguments) /* Constants (or statics in Rust speak) read by _start(). */
        *(.text._start_rust)      /* The Rust entry point */
        *(.text*)                 /* Everything else */
    } :segment_rx

    .rodata : ALIGN(8) { *(.rodata*) } :segment_rx
    .got    : ALIGN(8) { *(.got)     } :segment_rx

    /***********************************************************************************************
    * Data + BSS
    ***********************************************************************************************/
    .data : { *(.data*) } :segment_rw

    /* Section is zeroed in u64 chunks, align start and end to 8 bytes */
    .bss : ALIGN(8)
    {
        __bss_start = .;
        *(.bss*);
        . = ALIGN(8);

        . += 8; /* Fill for the bss == 0 case, so that __bss_start <= __bss_end_inclusive holds */
        __bss_end_inclusive = . - 8;
    } :NONE
}
```

上面就是一个链接文件。它反映出目标文件都包含着一些「段（section）」：代码段/数据段/bss段等等。

在上面链接文件中就定义了如下段：

- `.text`，指向代码段，其中*这个符号代表所有的输入文件的`.text section`合并成的一个。包含了 `_start` 入口，以及 Rust 函数 `_start_rust`等。
- `.rodata`，只读数据段。
- `.got`，全局偏移表（Global Offset Table），这是链接器在执行链接时实际上要填充的部分, 保存了所有外部符号的地址信息，在执行「重定向」时会用到。
- `.data`，数据段。指向所有输入文件的数据段，并且这个地址的起始为`0x800000`。
- `.bss`，全称`Block Started by Symbol segment`，常是指用来存放程序中未初始化的全局变量的一块内存区域，一般在初始化时`bss` 段部分将会清零（填充为0）。一般操作系统会做这个事。但是对于裸机，需要自己实现。上面链接代码里指定了 `bss` 段的范围和对齐。而清零工作将会由 Rust 代码来做。

> 为什么 `bss` 段一定要清零？
>
> 历史原因，让 C 语言及其他语言对于未初始化的全局变量都会默认设置为0，把这些变量存储在数据段还占空间，不如把它们放到 bss 段里，在程序运行之前再统一清零。所以，如果不清零，可能会出现一些问题。

## Rust 代码

在了解主要的汇编代码执行过程之后，再来看 Rust 代码就更容易理解了。

```rust
// _arch/aarch64/cpu/boot.rs
#[no_mangle]
pub unsafe fn _start_rust() -> ! {
    runtime_init::runtime_init()
}
```

上面定义了 `_start_rust` 的代码，执行逻辑很简单，就是对「运行环境初始化」。

```rust
// src/runtime_init.rs
use crate::{bsp, memory};

//--------------------------------------------------------------------------------------------------
// Private Code
//--------------------------------------------------------------------------------------------------

/// Zero out the .bss section.
///
/// # Safety
///
/// - Must only be called pre `kernel_init()`.
#[inline(always)]
unsafe fn zero_bss() {
    // 调用 memory 模块定义的 `zero_volatile`函数，整个函数不会被 Rust 编译器重排。
    memory::zero_volatile(bsp::memory::bss_range_inclusive());
}

//--------------------------------------------------------------------------------------------------
// Public Code
//--------------------------------------------------------------------------------------------------
// 这里等价于 C/C++ 世界的 `crt0` 
/// Equivalent to `crt0` or `c0` code in C/C++ world. Clears the `bss` section, then jumps to kernel
/// init code.
///
/// # Safety
///
/// - Only a single core must be active and running this function.
pub unsafe fn runtime_init() -> ! {
    zero_bss();

    crate::kernel_init()
}
```

`runtime_init` 函数所做的也很简单：

1. 对 `bss` 段清零。
2. 调用 `crate::kernel_init()` 初始化内核。只不过现在还没有任何内核代码。

```rust
// /src/bsp/raspberrypi/memory.rs

use core::{cell::UnsafeCell, ops::RangeInclusive};

//--------------------------------------------------------------------------------------------------
// Private Definitions
//--------------------------------------------------------------------------------------------------

// 使用 Rust ABI 
// 定义出现在链接脚本的符号 
// Symbols from the linker script.
extern "Rust" {
    static __bss_start: UnsafeCell<u64>;
    static __bss_end_inclusive: UnsafeCell<u64>;
}

//--------------------------------------------------------------------------------------------------
// Public Code
//--------------------------------------------------------------------------------------------------
// 返回 bss 段地址范围
/// Return the inclusive range spanning the .bss section.
///
/// # Safety
///
/// - Values are provided by the linker script and must be trusted as-is.
/// - The linker-provided addresses must be u64 aligned.
pub fn bss_range_inclusive() -> RangeInclusive<*mut u64> {
    let range;
    unsafe {
        range = RangeInclusive::new(__bss_start.get(), __bss_end_inclusive.get());
    }
    assert!(!range.is_empty());

    range
}
```

上面代码定义了 bss 段相关。

```rust
// src/bsp/raspberrypi/cpu.rs

#[no_mangle]
#[link_section = ".text._start_arguments"]
pub static BOOT_CORE_ID: u64 = 0;
```

这里定义了 `BOOT_CORE_ID`，在汇编代码里用到。指定内核id为0的进入待机模式。

```rust
// src/memory.rs

use core::ops::RangeInclusive;

//--------------------------------------------------------------------------------------------------
// Public Code
//--------------------------------------------------------------------------------------------------

/// Zero out an inclusive memory range.
///
/// # Safety
///
/// - `range.start` and `range.end` must be valid.
/// - `range.start` and `range.end` must be `T` aligned.
pub unsafe fn zero_volatile<T>(range: RangeInclusive<*mut T>)
where
    T: From<u8>,
{
    let mut ptr = *range.start();
    let end_inclusive = *range.end();

    while ptr <= end_inclusive {
        core::ptr::write_volatile(ptr, T::from(0));
        ptr = ptr.offset(1);
    }
}
```

再来看 `zero_volatile` 函数，专门用于对 bss 段清零。内部使用了 `core::ptr::write_volatile`函数，防止 Rust 编译器指令重排。就是对指针相应内存地址填充 `0`。

## 小结

千里之行，始于足下。

要编写一个嵌入式操作系统，得先从初始化运行环境开始。虽然代码不多，但是相关知识确实不少。再搞明白汇编代码的过程中，了解 ARM 架构下多核代码执行，以及从零开始理解 语言运行时（Runtime，为了避免混淆，我更愿意称之为运行环境） 的概念，更加直观清晰。


