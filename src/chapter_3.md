# 硬核输出 Hello World

在准备好执行环境之后，我们要输出 "Hello World" 了。

## 代码释意

这里只列出相对第二章的代码变化。代码释意在注释中。

 ```rust
// src/main.rs
// 在执行环境准备好以后，跳到内核初始化代码，我们将在这里打印 hello world
/// Early init code.
///
/// # Safety
///
/// - Only a single core must be active and running this function.
unsafe fn kernel_init() -> ! {
    println!("[0] Hello from Rust!");

    panic!("Stopping here.")
}
 ```

此处 `panic!` 已经在 `src/panic_wait.rs` 内被定义：

```rust
// src/panic_wait.rs
#[panic_handler]
fn panic(info: &PanicInfo) -> ! {
    if let Some(args) = info.message() {
        println!("\nKernel panic: {}", args);
    } else {
        println!("\nKernel panic!");
    }

    cpu::wait_forever()
}
```

而 `println!` 在 `src/print.rs` 中被定义：

```rust
// src/print.rs

pub fn _print(args: fmt::Arguments) {
    use console::interface::Write;

    bsp::console::console().write_fmt(args).unwrap();
}

#[macro_export]
macro_rules! println {
    () => ($crate::print!("\n"));
    ($($arg:tt)*) => ({
        $crate::print::_print(format_args_nl!($($arg)*));
    })
}

```

注意到这个 `println!`实现内部多了 `console` 模块。在 `console` 模块中定义了 一个 `interface` 内部模块：

```rust
// src/consol.rs

/// Console interfaces.
pub mod interface {
    // 这里重新导出了 core 中定义的 `fmt::Write`。

    /// Console write functions.
    ///
    /// `core::fmt::Write` is exactly what we need for now. Re-export it here because
    /// implementing `console::Write` gives a better hint to the reader about the
    /// intention.
    pub use core::fmt::Write;
}
```

具体的实现在 `src/bsp/raspberrypi/console.rs`中：

```rust
// src/bsp/raspberrypi/console.rs

use crate::console;
use core::fmt;

//--------------------------------------------------------------------------------------------------
// Private Definitions
//--------------------------------------------------------------------------------------------------

// 因为目前只支持在 QEMU 中进行输出
/// A mystical, magical device for generating QEMU output out of the void.
struct QEMUOutput;

//--------------------------------------------------------------------------------------------------
// Private Code
//--------------------------------------------------------------------------------------------------

// 实现 `core::fmt::Write` trait 就可以使用 `format_args!` 宏，此宏可以避免堆分配。通过实现 `write_str()` 就可以自动得到 `write_fmt()`，因为`write_fmt()`的默认实现依赖 `write_str()` 的实现。

/// Implementing `core::fmt::Write` enables usage of the `format_args!` macros, which in turn are
/// used to implement the `kernel`'s `print!` and `println!` macros. By implementing `write_str()`,
/// we get `write_fmt()` automatically.
///
/// See [`src/print.rs`].
///
/// [`src/print.rs`]: ../../print/index.html
impl fmt::Write for QEMUOutput {
    fn write_str(&mut self, s: &str) -> fmt::Result {
        for c in s.chars() {
            unsafe {
                // write_volatile不会drop dst的内容。 
                // 这是安全的，但可能会泄漏分配或资源，因此应注意不要覆盖应 drop 的对象。
                // 此外，它不会 drop src。 语义上，src被移动到dst指向的位置。
                // 0x3F20_1000 地址为 UART0 (serial port, PL011)
                core::ptr::write_volatile(0x3F20_1000 as *mut u8, c as u8);
            }
        }

        Ok(())
    }
}

//--------------------------------------------------------------------------------------------------
// Public Code
//--------------------------------------------------------------------------------------------------

/// Return a reference to the console.
pub fn console() -> impl console::interface::Write {
    QEMUOutput {}
}
```

这就是第三章新增的一些代码，其他代码和第二章相比没有什么变化。

## 关于 `UnsafeCell<u64>` 的用法

在 `src/bsp/raspberrypi/memory.rs` 的代码中，定义 `bss` 段的 start 和 end 指针，用了 `UnsafeCell<64>`。

```rust
// Symbols from the linker script.
extern "Rust" {
    static __bss_start: UnsafeCell<u64>;
    static __bss_end_inclusive: UnsafeCell<u64>;
}
```

此处有朋友提到一个问题：

为什么这里用 `UnsafeCell<u64>` ？用 `usize` 不是更方便吗？像下面这样：

```rust
extern "C" {
    static __bss_start: usize;
    static __bss_end: usize;
}

pub fn bss_range() -> Range<*mut u64> {
    unsafe {
        Range {
            start: &__bss_start as *const _ as *mut u64,
            end: &__bss_end as *const _ as *mut u64,
        }
    }
}
```

其实这个教程的作者之前和 RalfJung （Rust 官方语言团队）讨论过：[https://github.com/rust-lang/nomicon/issues/109](https://github.com/rust-lang/nomicon/issues/109)。

使用 引用 来获取 `*mut T`，属于 UB。 Rust 里合法获取 `*mut T` 的方式就是用 `UnsafeCell<T>` 。

当然，你也可以像 [清华大学 rCore 教程](https://rcore-os.github.io/rCore-Tutorial-Book-v3/chapter1/3-2-mini-rt-baremetal.html#bss)那样来写：

```rust
// os/src/main.rs
fn clear_bss() {
    extern "C" {
        fn sbss();
        fn ebss();
    }
    (sbss as usize..ebss as usize).for_each(|a| {
        unsafe { (a as *mut u8).write_volatile(0) }
    });
}
```

因为不去构造 Rust 类型实例，直接使用链接脚本 `linker.ld` 中给出的全局符号 `sbss` 和 `ebss` 来确定 `.bss` 段的位置，所以是安全的。

## `cortex-a` 库 介绍

本教程第二章开始引入了这个库。

```rust
// Cargo.toml
[dependencies]

# Platform specific dependencies
[target.'cfg(target_arch = "aarch64")'.dependencies]
cortex-a = { version = "5.x.x" }
```

[cortex-a](https://github.com/rust-embedded/cortex-a) 库是对 Cortex-A 处理器底层访问的封装。树莓派系列用的处理器就是 Cortex-A 系列。

该库目前只支持  AArch64 。使用它必须要求 rustc 版本在 1.45.0 及以上，因为要使用新的 `asm!` 宏。旧的`asm!`已经被改名为 `llvm_asm!`。

[ARMv8-A architecture 相关参考资料](https://developer.arm.com/documentation/ddi0487/latest/)


## 补充知识：介绍 树莓派的 UART 

本章的打印，只是利用了 QEMU 来模拟（src/bsp/raspberrypi/console.rs）使用了树莓派的 `UART` 功能。后面的课程会应用到树莓派真实的 `UART`。

**什么是 UART**

通用异步收发传输器（Universal Asynchronous Receiver/Transmitter），通常称作 UART，是一种异步收发传输器，是电脑硬件的一部分。它将要传输的资料在串行通信与并行通信之间加以转换。作为把并行输入信号转成串行输出信号的芯片，UART通常被集成于其他通讯接口的连结上。

UART 是一种通用串行数据总线，用于异步通信。该总线双向通信，可以实现全双工传输和接收。在嵌入式设计中，UART 用于主机与辅助设备通信，如汽车音响与外接 AP 之间的通信，与 PC 机通信包括与监控调试器和其它器件，如 EEPROM 通信。

UART 用一条传输线将数据一位位地顺序传送，以字符为传输单位，通信中两个字符间的时间间隔多少是不固定的， 然而在同一个字符中的两个相邻位间的时间间隔是固定的，数据传送速率用波特率来表示， 指单位时间内载波参数变化的次数， 或每秒钟传送的二进制位数。如每秒钟传送 240 个字符， 而每个字符包含 10 位（1个起始位， 1个停止位， 8个数据位）， 这时的波特率为`2400Bd`。

**同步 vs 异步**

同步是指，发送方发出数据后，等接收方发回响应以后才发下一个数据包的通讯方式；异步是指，发送方发出数据后，不等接收方发回响应，接着发送下个数据包的通讯方式。换句话说，同步通信是阻塞方式，异步通信是非阻塞方式。在常见通信总线协议中，I2C，SPI属于同步通信而 UART 属于异步通信。同步通信的通信双方必须先建立同步，即双方的时钟要调整到同一个频率，收发双方不停地发送和接收连续的同步比特流。异步通信在发送字符时，发送端可以在任意时刻开始发送字符，所以，在UART通信中，数据起始位和停止位是必不可少的。

UART 协议层中，规定了数据包的内容，它由起始位、主体数据、校验位以及停止位组成，通信双方的数据包格式要约定一致才能正常收发数据 

**中断控制**

出现以下情况时，可使 UART 产生中断：

- FIFO 溢出错误
- 线中止错误（line-break，即Rx 信号一直为0 的状态，包括校验位和停止位在内）
- 奇偶校验错误
- 帧错误（停止位不为1）
- 接收超时（接收FIFO 已有数据但未满，而后续数据长时间不来）
- 发送
- 接收
- 由于所有中断事件在发送到中断控制器之前会一起进行“或运算”操作，所以任意时刻 UART 只能向中断产生一个中断请求。通过查询中断状态函数`UARTIntStatus()`，软件可以在同一个中断服务函数里处理多个中断事件（多个并列的`if` 语句）。

**Raspberry Pi UART**

Raspberry Pi有两个内置UART:

- PL011 UART，基于 ARM 的 UART， 具有更高吞吐量。
- mini UART

在 Raspberry Pi 3中，mini UART 用于 Linux 控制台输出，而 PL011 用于板载蓝牙模块。树莓派 4 中新增了 4 个 PL011 串口共计有 6 个 UART。

各 UART 串口与 GPIO 对应关系：

```text
GPIO14 = TXD0 -> ttyAMA0
GPIO0  = TXD2 -> ttyAMA1
GPIO4  = TXD3 -> ttyAMA2
GPIO8  = TXD4 -> ttyAMA3
GPIO12 = TXD5 -> ttyAMA4

GPIO15 = RXD0 -> ttyAMA0
GPIO1  = RXD2 -> ttyAMA1
GPIO5  = RXD3 -> ttyAMA2
GPIO9  = RXD4 -> ttyAMA3
GPIO13 = RXD5 -> ttyAMA4
```

## 小结

本节内容如果理解了第二章，剩下的就很简单了。当然需要你对 Rust 的基础知识有一定了解。

另外，本节的 `Makefile` 中 `QEMU_RELEASE_ARGS` 配置也做了一些修改。
