# 安全访问全局数据结构

> 从这一章开始，我修改了 Makefile 中配置 `QEMU_MACHINE_TYPE = raspi4`，默认使用 树莓派4。

前一章在内核初始化的时候打印 Hello World。然而并没有考虑多核的情况。

在前一章的打印代码中，每次打印都重新生成一个 `QEMUOutput` 实例。

```rust
// in src/print.rs

#[doc(hidden)]
pub fn _print(args: fmt::Arguments) {
    use console::interface::Write;

    bsp::console::console().write_fmt(args).unwrap();
}

// in src/bsp/raspberrypi/console.rs

struct QEMUOutput;
/// Return a reference to the console.
pub fn console() -> impl console::interface::Write {
    QEMUOutput {}
}
```

如果想保留某些状态，比如记录写入的字符数的统计信息，我们就需要创建一个`QEMUOutput`的全局实例。因此就需要实现一个同步锁了。这一章实现了一个「假锁」作为示意。

## 代码释意

只记录基于第三章代码的改进，注意代码注释。

在 `src/main.rs` 中：

```rust
unsafe fn kernel_init() -> ! {
    // 新增 Statistics
    use console::interface::Statistics;

    println!("[0] Hello from Rust!");

    // 新增字符计数功能
    println!(
        "[1] Chars written: {}",
        bsp::console::console().chars_written()
    );

    println!("[2] Stopping here.");
    cpu::wait_forever()
}
```

来看一下 `src/console.rs` 代码：

```rust
/// Console interfaces.
pub mod interface {
    use core::fmt;

    // 之前是对 core 库的重导出，现在改为了自定义 Write trait
    /// Console write functions.
    pub trait Write {
        /// Write a Rust format string.
        fn write_fmt(&self, args: fmt::Arguments) -> fmt::Result;
    }

    // 增加用于统计写入字符数目的 trait
    /// Console statistics.
    pub trait Statistics {
        /// Return the number of characters written.
        fn chars_written(&self) -> usize {
            0
        }
    }

    // 这里使用了 trait 别名
    // 实际上在 main.rs 中引入了 `#![feature(trait_alias)]`
    /// Trait alias for a full-fledged console.
    pub trait All = Write + Statistics;
}
```

然后看看 `src/bsp/raspberrypi/console.rs` 中的具体实现：

```rust

// QEMUOutputInner 用于统计字符
/// A mystical, magical device for generating QEMU output out of the void.
///
/// The mutex protected part.
struct QEMUOutputInner {
    chars_written: usize,
}

/// The main struct.
pub struct QEMUOutput {
    // 这里新增 NullLock （伪）锁来（假装）保证多核同步
    inner: NullLock<QEMUOutputInner>,
}

//--------------------------------------------------------------------------------------------------
// Global instances 全局实例
//--------------------------------------------------------------------------------------------------
static QEMU_OUTPUT: QEMUOutput = QEMUOutput::new();

impl QEMUOutputInner {
    const fn new() -> QEMUOutputInner {
        QEMUOutputInner { chars_written: 0 }
    }

    // 获取锁以后才能调用该方法来打印并统计字符
    /// Send a character.
    fn write_char(&mut self, c: char) {
        unsafe {
            // `0x3F20_1000` 为 UART0 (serial port, PL011) MMIO 地址
            core::ptr::write_volatile(0x3F20_1000 as *mut u8, c as u8);
        }

        self.chars_written += 1;
    }
}

// 此处给 QEMUOutputInner 实现 `core::fmt::Write` 

/// Implementing `core::fmt::Write` enables usage of the `format_args!` macros, which in turn are
/// used to implement the `kernel`'s `print!` and `println!` macros. By implementing `write_str()`,
/// we get `write_fmt()` automatically.
///
/// The function takes an `&mut self`, so it must be implemented for the inner struct.
///
/// See [`src/print.rs`].
///
/// [`src/print.rs`]: ../../print/index.html
impl fmt::Write for QEMUOutputInner {
    fn write_str(&mut self, s: &str) -> fmt::Result {
        for c in s.chars() {
            // Convert newline to carrige return + newline.
            if c == '\n' {
                // 注意，这里调用了自定义的 write_char，在输出的时候进行统计
                self.write_char('\r')
            }

            self.write_char(c);
        }

        Ok(())
    }
}

impl QEMUOutput {
    /// Create a new instance.
    pub const fn new() -> QEMUOutput {
        QEMUOutput {
            inner: NullLock::new(QEMUOutputInner::new()),
        }
    }
}

// 注意这里使用来 trait `All`
/// Return a reference to the console.
pub fn console() -> &'static impl console::interface::All {
    &QEMU_OUTPUT
}

//------------------------------------------------------------------------------
// OS Interface Code 这里实现同步锁(Mutex)
//------------------------------------------------------------------------------
use synchronization::interface::Mutex;

// 注意这里实现的是自定义的 `Write` trait
/// Passthrough of `args` to the `core::fmt::Write` implementation, but guarded by a Mutex to
/// serialize access.
impl console::interface::Write for QEMUOutput {
    fn write_fmt(&self, args: core::fmt::Arguments) -> fmt::Result {
        // Fully qualified syntax for the call to `core::fmt::Write::write:fmt()` to increase
        // readability.
        // 获取锁以后，传入一个 FnOnce 闭包
        self.inner.lock(|inner| fmt::Write::write_fmt(inner, args))
    }
}

impl console::interface::Statistics for QEMUOutput {
    // 该方法在 main 中被调用
    fn chars_written(&self) -> usize {
        self.inner.lock(|inner| inner.chars_written)
    }
}
```

在来看一下 `src/synchronization.rs` 中 （伪）锁的实现：

```rust
// 利用 UnsafeCell 来实现锁
use core::cell::UnsafeCell;

//--------------------------------------------------------------------------------------------------
// Public Definitions
//--------------------------------------------------------------------------------------------------

/// Synchronization interfaces.
pub mod interface {

    // 实现一个 Mutex trait，任何实现了该 trait 的类型，都需要提供一个闭包来访问数据
    /// Any object implementing this trait guarantees exclusive access to the data wrapped within
    /// the Mutex for the duration of the provided closure.
    pub trait Mutex {
        /// The type of the data that is wrapped by this mutex.
        type Data;

        /// Locks the mutex and grants the closure temporary mutable access to the wrapped data.
        fn lock<R>(&self, f: impl FnOnce(&mut Self::Data) -> R) -> R;
    }
}

// `NullLock<T>` （伪）锁是为了教学目的而实现。因为我们现在是裸机编程，没有任何同步原语可以使用。

/// A pseudo-lock for teaching purposes.
///
/// In contrast to a real Mutex implementation, does not protect against concurrent access from
/// other cores to the contained data. This part is preserved for later lessons.
///
/// The lock will only be used as long as it is safe to do so, i.e. as long as the kernel is
/// executing single-threaded, aka only running on a single core with interrupts disabled.
pub struct NullLock<T>
where
    T: ?Sized,
{
    data: UnsafeCell<T>,
}

//--------------------------------------------------------------------------------------------------
// Public Code
//--------------------------------------------------------------------------------------------------

unsafe impl<T> Send for NullLock<T> where T: ?Sized + Send {}
unsafe impl<T> Sync for NullLock<T> where T: ?Sized + Send {}

impl<T> NullLock<T> {
    /// Create an instance.
    pub const fn new(data: T) -> Self {
        Self {
            data: UnsafeCell::new(data),
        }
    }
}

//------------------------------------------------------------------------------
// OS Interface Code
//------------------------------------------------------------------------------

// 为`NullLock<T>`实现自定义的 Mutex trait
impl<T> interface::Mutex for NullLock<T> {
    type Data = T;

    fn lock<R>(&self, f: impl FnOnce(&mut Self::Data) -> R) -> R {
        // 在真正的锁中，将有代码封装此行，以确保每次只能给出一次此可变引用。
        // 真正的锁实现可以参考：
        //    1. https://github.com/Amanieu/parking_lot/blob/master/src/mutex.rs
        //    2. https://github.com/mvdnes/spin-rs/blob/master/src/mutex.rs
        // In a real lock, there would be code encapsulating this line that ensures that this
        // mutable reference will ever only be given out once at a time.
        let data = unsafe { &mut *self.data.get() };

        f(data)
    }
}
```

## 树莓派相关背景知识

**Makefile 配置文件中：**

```rust
QEMU_RELEASE_ARGS = -serial stdio -display none
```

该配置将模拟的 UART0 重定向到运行 qemu 的终端的标准输入 / 输出，以便显示发送到串行线路的所有内容，并且 vm 会接收终端中键入的每个键。

**MMIO 映射外部设备**

`memory-mapped I/O` 把设备寄存器映射成常规的数据空间。对它的访问与访问系统内存空间没有区别。

而`port I/O `把控制和数据寄存器映射到一个单独的数据空间。`port I/O` 和 `memory-mapped I/O` 相似，除了，程序必须使用特殊的指令（如 Intel x86 处理器的 `in` 和 `out` 指令）来写入或者读取设备寄存器。

一些更有趣的 MMIO 地址是：

- `0x3F003000`- System Timer
- `0x3F00B000`- Interrupt controller
- `0x3F00B880`- VideoCore mailbox
- `0x3F100000`- Power management
- `0x3F104000`- Random Number Generator
- `0x3F200000`- General Purpose IO controller
- `0x3F201000`- UART0 (serial port, PL011)
- `0x3F215000`- UART1 (serial port, AUX mini UART)
- `0x3F300000`- External Mass Media Controller (SD card reader)
- `0x3F980000`- Universal Serial Bus controller

## 小结

从底层裸机多核视角来面对并发问题，很有意思。