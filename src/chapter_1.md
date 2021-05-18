# Chapter 1 ：Wait Forever

这一章的内容很简单，就是构建了一个死循环。还没有任何内核代码。

## 代码解释

一、先看 `main.rs` ：

```rust
#![feature(asm)]
#![feature(global_asm)]
#![no_main]
#![no_std]

mod bsp;
mod cpu;
mod panic_wait;

// Kernel code coming next tutorial.
```

这段代码中，用到了两个 Feature Gate : `#![feature(asm)]` 和 `#![feature(global_asm)]`，只有Nightly Rust 下才可以用它们，这表示我们要使用内联汇编功能。

注意另外也用了 `#![no_main]` 和 `#![no_std]`，因为现在是面向 bare metal 编程，无法使用标准库。


二、 再看 `cpu` 模块：

```rust
// cpu/boot.rs 
#[cfg(target_arch = "aarch64")]
#[path = "../_arch/aarch64/cpu/boot.rs"]
mod arch_boot;
```

这个通过 `#[path = "../_arch/aarch64/cpu/boot.rs"]`来指定具体的模块路径，实际上是 `_arch/aarch64/cpu/boot.rs`。

```rust
// _arch/aarch64/cpu/boot.rs

global_asm!(include_str!("boot.s"));
```

而这个 `boot.rs` 中则使用 `global_asm!` 来加载外部汇编源码文件`boot.s`。

三、 汇编代码释疑

```rust

//--------------------------------------------------------------------------------------------------
// Public Code
//--------------------------------------------------------------------------------------------------
.section .text._start

//------------------------------------------------------------------------------
// fn _start()
//------------------------------------------------------------------------------
_start:
	// Infinitely wait for events (aka "park the core").
1:	wfe         // 设置 标签 1，使用指令 wfe ，等待某个事件，让 ARM 核进入待机模式
	b	1b      // 跳转回 标签 1

.size	_start, . - _start 
.type	_start, function
.global	_start  
```

这段汇编代码是 ARM 汇编，结合相关汇编知识，我们可以看出，这段代码是将整个程序设置为待机模式。

此处穿插一些相关的 ARM 汇编基础：

> `wfi` 和 `wfe`:
> 
> `wfi (Wait for interrupt)`和`wfe (Wait for event)`是两个让ARM核进入`low-power standby`模式的指令，由ARM architecture定义，由ARM core实现。`spinlock`实现一般和 `wfe`指令有关。
>
> standby 一般为待机模式。
>
> 对WFI来说，执行WFI指令后，ARM core会立即进入low-power standby state，直到有WFI Wakeup events发生。
>
> 而WFE则稍微不同，执行WFE指令后，根据Event Register（一个单bit的寄存器，每个PE一个）的状态，有两种情况：如果Event Register为1，该指令会把它清零，然后执行完成（不会standby）；如果Event Register为0，和WFI类似，进入low-power standby state，直到有WFE Wakeup events发生。


四、 BSP

因为现在只能用 qemu，所以 BSP 就暂时无效。

五、 Panic Handler 

在标准库中，Panic 已经被定义。但是在不使用标准库的 `no-std` 环境，Panic 属于未定义，所以我们需要定义它的行为。

```rust
// panic_wait.rs

use core::panic::PanicInfo;

#[panic_handler]
fn panic(_info: &PanicInfo) -> ! {
    unimplemented!()
}
```

`＃[panic_handler]`用于定义恐慌的行为！在`＃！[no_std]`应用程序中。 `＃[panic_handler]`属性必须应用于签名为`fn（＆PanicInfo）-> !` 的函数。 并且该函数必须在 `binary / dylib / cdylib` crate 的依赖关系图中出现一次。 

鉴于嵌入式系统的范围从用户面临的问题到对安全至关重要的问题（不会崩溃），没有一种大小适合所有恐慌行为，但是有很多常用行为。 这些常见行为已打包到定义`＃[panic_handler]`函数的 crate 中。 一些示例包括：

- [panic-abort](https://crates.io/crates/panic-abort) 。Panic 会导致执行中止（abort）指令。
- [panic-halt](https://crates.io/crates/panic-halt) 。Panic 会导致程序或当前线程通过进入无限循环而暂停。
- [panic-itm](https://crates.io/crates/panic-itm) 。Panic 消息是使用ITM（ARM Cortex-M特定的外围设备）记录的。
- [panic-semihosting](https://crates.io/crates/panic-semihosting) 。Panic 消息将使用半主机（semihosting）技术记录到主机。

> 参考： [https://docs.rust-embedded.org/book/start/panicking.html](https://docs.rust-embedded.org/book/start/panicking.html)

六、 `build.rs`

```rust
// build.rs
use std::env;

fn main() {
    let linker_file = env::var("LINKER_FILE").unwrap();

    println!("cargo:rerun-if-changed={}", linker_file);
    println!("cargo:rerun-if-changed=build.rs");
}
```

使用 `build.rs` 来传递 `LINKER_FILE`，目前用不到。等第六章可以使用树莓派实体的时候就可以用了。

## 观察代码运行结果

在 `01_wait_forever` 目录下执行命令：

```
> make qemu
```

注意：不要更改 Makefile 中默认的 `rpi3` 为 `rpi4`，不支持。

输出结果：

```rust
Launching QEMU
----------------
IN: 
0x00000000:  580000c0  ldr      x0, #0x18  
0x00000004:  aa1f03e1  mov      x1, xzr // 写入 xzr 寄存器的数据被忽略，读出的数据全为0，此处为初始化寄存器 x1,x2,x3
0x00000008:  aa1f03e2  mov      x2, xzr
0x0000000c:  aa1f03e3  mov      x3, xzr
0x00000010:  58000084  ldr      x4, #0x20
0x00000014:  d61f0080  br       x4

----------------
IN: 
0x00080000:  d503205f  wfe              // wef 进入 待机模式
0x00080004:  17ffffff  b        #0x80000  // 跳转到 地址 0x00080000

----------------
IN: 
0x00000300:  d2801b05  mov      x5, #0xd8  // 从 #0xd8 移动数据到 寄存器 x5，额外工作
// mrs 状态寄存器到通用寄存器的传送指令
0x00000304:  d53800a6  mrs      x6, mpidr_el1 // mpidr_el1 寄存器在多处理器系统中，为调度提供一个额外的PE（process element）识别机制
0x00000308:  924004c6  and      x6, x6, #3 // #3的值与06相位与后的值传送到X6
0x0000030c:  d503205f  wfe      
0x00000310:  f86678a4  ldr      x4, [x5, x6, lsl #3]
0x00000314:  b4ffffc4  cbz      x4, #0x30c // CBZ  ;比较（Compare），如果结果为零（Zero）就转移（只能跳到后面的指令），此处跳转到 地址 0x0000030c

----------------
IN: 
0x00000300:  d2801b05  mov      x5, #0xd8
0x00000304:  d53800a6  mrs      x6, mpidr_el1
0x00000308:  924004c6  and      x6, x6, #3
0x0000030c:  d503205f  wfe      
0x00000310:  f86678a4  ldr      x4, [x5, x6, lsl #3]
0x00000314:  b4ffffc4  cbz      x4, #0x30c // CBZ  ;比较（Compare），如果结果为零（Zero）就转移（只能跳到后面的指令），此处跳转到 地址 0x0000030c

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
0x00000314:  b4ffffc4  cbz      x4, #0x30c // CBZ  ;比较（Compare），如果结果为零（Zero）就转移（只能跳到后面的指令），此处跳转到 地址 0x0000030c

----------------
IN: 
0x0000030c:  d503205f  wfe      
0x00000310:  f86678a4  ldr      x4, [x5, x6, lsl #3]
0x00000314:  b4ffffc4  cbz      x4, #0x30c  // CBZ  ;比较（Compare），如果结果为零（Zero）就转移（只能跳到后面的指令），此处跳转到 地址 0x0000030c
```

CPU 可以通过物理地址来 逐字节 访问物理内存中保存的 数据，一般程序通常以 `0x8000`开头。

为什么总是以 `0x8000`这个地址开头呢？历史原因吧，一些系统在 `0x000` ~ `0x8000` 之间另作他用。比如Unix 把`0x000` 地址 作为空指针。

注： PE 代表Processing Element，它是ARM架构对处理单元的抽象，为方便理解，就把它当做ARM cores好了