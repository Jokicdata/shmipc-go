# C 语言与 Go 语言互操作原理详解

## 目录

1. [概述](#一概述)
2. [CGO 基础](#二cgo-基础)
3. [Go 调用 C 函数](#三go-调用-c-函数)
4. [C 调用 Go 函数](#四c-调用-go-函数)
5. [数据类型转换](#五数据类型转换)
6. [内存管理](#六内存管理)
7. [回调函数](#七回调函数)
8. [构建共享库](#八构建共享库)
9. [实战案例](#九实战案例)
10. [常见问题与陷阱](#十常见问题与陷阱)

---

## 一、概述

### 1.1 什么是 CGO

CGO 是 Go 语言提供的一种机制，允许 Go 程序调用 C 语言代码，同时也允许 C 语言代码调用 Go 函数。这使得 Go 可以：

1. 复用现有的 C 语言库
2. 编写需要与 C 语言交互的系统级代码
3. 创建可被 C 程序调用的共享库

### 1.2 CGO 工作原理

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                              CGO 工作原理                                        │
├─────────────────────────────────────────────────────────────────────────────────┤
│                                                                                 │
│   Go 源代码 (.go)                                                               │
│  ┌──────────────────────────────────────────────────────────────────────────┐  │
│  │  package main                                                            │  │
│  │                                                                          │  │
│  │  /*                                                                      │  │
│  │  #include <stdio.h>                    // C 代码块                        │  │
│  │  void hello() { printf("Hello from C\n"); }                              │  │
│  │  */                                                                      │  │
│  │  import "C"                              // CGO 导入                      │  │
│  │                                                                          │  │
│  │  func main() {                                                           │  │
│  │      C.hello()                           // Go 调用 C                     │  │
│  │  }                                                                       │  │
│  └──────────────────────────────────────────────────────────────────────────┘  │
│                                           │                                     │
│                                           ▼                                     │
│  ┌──────────────────────────────────────────────────────────────────────────┐  │
│  │                           CGO 编译流程                                    │  │
│  │                                                                          │  │
│  │   1. cgo 工具解析 Go 源码中的 C 代码块                                    │  │
│  │   2. 生成 C 代码桩文件 (_cgo_export.c, _cgo_main.c)                       │  │
│  │   3. 生成 Go 代码桩文件 (_cgo_gotypes.go)                                 │  │
│  │   4. C 编译器编译 C 代码生成目标文件                                       │  │
│  │   5. Go 编译器编译 Go 代码                                                │  │
│  │   6. 链接器链接所有目标文件生成最终可执行文件                               │  │
│  │                                                                          │  │
│  └──────────────────────────────────────────────────────────────────────────┘  │
│                                                                                 │
└─────────────────────────────────────────────────────────────────────────────────┘
```

### 1.3 核心组件

| 组件 | 说明 |
|------|------|
| `import "C"` | CGO 的核心导入，启用 CGO 功能 |
| `/* ... */` | C 代码块，位于 import "C" 之前 |
| `C.xxx` | 在 Go 中访问 C 的类型、函数、变量 |
| `//export` | 导出 Go 函数供 C 调用 |
| `cgo` 工具 | Go 自带的 CGO 处理工具 |

---

## 二、CGO 基础

### 2.1 基本语法结构

```go
package main

/*
// C 代码块开始
// 这里可以写任意的 C 代码
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// C 函数定义
int add(int a, int b) {
    return a + b;
}

// C 变量定义
int global_var = 100;

// C 类型定义
typedef struct {
    int x;
    int y;
} Point;
// C 代码块结束
*/
import "C"  // 必须紧跟在 C 代码块之后，中间不能有空行

import "fmt"

func main() {
    // 调用 C 函数
    result := C.add(1, 2)
    fmt.Println("Result:", result)
    
    // 访问 C 变量
    fmt.Println("Global var:", C.global_var)
    
    // 使用 C 类型
    var p C.Point
    p.x = 10
    p.y = 20
    fmt.Printf("Point: (%d, %d)\n", p.x, p.y)
}
```

### 2.2 C 代码块的位置规则

```go
package main

/*
C 代码块必须：
1. 紧邻 package 语句之后
2. 使用 /* */ 注释格式（不支持 //）
3. import "C" 必须紧跟在 C 代码块之后

错误示例：
*/

// ❌ 错误：C 代码块和 import "C" 之间有空行
/*
#include <stdio.h>
*/

import "C"  // 编译错误！

// ❌ 错误：使用 // 注释
// #include <stdio.h>
// import "C"  // 不支持这种格式

// ✅ 正确格式
/*
#include <stdio.h>
*/
import "C"
```

### 2.3 引用 C 头文件

```go
package main

/*
// 方式 1：直接包含系统头文件
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// 方式 2：包含自定义头文件
#include "myheader.h"

// 方式 3：使用条件编译
#ifdef __linux__
#include <unistd.h>
#endif

// 方式 4：定义宏
#define MAX_SIZE 1024
#define ADD(a, b) ((a) + (b))
*/
import "C"

func main() {
    // 使用宏定义的常量
    buf := make([]byte, C.MAX_SIZE)
    
    // 使用宏定义的函数
    result := C.ADD(1, 2)
}
```

### 2.4 CGO 编译标签

```go
//go:build linux
// +build linux

package main

/*
// 仅在 Linux 平台编译
#include <sys/epoll.h>
*/
import "C"

// 或者使用条件编译

/*
#ifdef __linux__
#include <sys/epoll.h>
#endif
*/
import "C"
```

---

## 三、Go 调用 C 函数

### 3.1 调用 C 标准库函数

```go
package main

/*
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
*/
import "C"
import "fmt"
import "unsafe"

func main() {
    // 1. printf
    C.printf(C.CString("Hello from Go!\n"))
    
    // 2. malloc/free
    ptr := C.malloc(100)
    defer C.free(ptr)  // 记得释放内存
    
    // 3. memcpy
    src := []byte("Hello")
    dst := (*[5]byte)(ptr)
    C.memcpy(unsafe.Pointer(dst), unsafe.Pointer(&src[0]), 5)
    
    // 4. time
    t := C.time(nil)
    fmt.Println("Current time:", t)
}
```

### 3.2 调用自定义 C 函数

```go
package main

/*
#include <stdlib.h>

// 简单函数
int add(int a, int b) {
    return a + b;
}

// 指针参数函数
void swap(int *a, int *b) {
    int temp = *a;
    *a = *b;
    *b = temp;
}

// 字符串处理函数
int string_length(const char *str) {
    return strlen(str);
}

// 结构体相关函数
typedef struct {
    int x;
    int y;
} Point;

Point* create_point(int x, int y) {
    Point *p = (Point*)malloc(sizeof(Point));
    p->x = x;
    p->y = y;
    return p;
}

void free_point(Point *p) {
    free(p);
}

int point_distance(Point *p) {
    return p->x * p->x + p->y * p->y;
}
*/
import "C"
import "fmt"
import "unsafe"

func main() {
    // 调用简单函数
    sum := C.add(10, 20)
    fmt.Println("Sum:", sum)
    
    // 调用指针参数函数
    var a, b C.int = 1, 2
    C.swap(&a, &b)
    fmt.Printf("After swap: a=%d, b=%d\n", a, b)
    
    // 调用字符串处理函数
    cstr := C.CString("Hello CGO")
    defer C.free(unsafe.Pointer(cstr))
    length := C.string_length(cstr)
    fmt.Println("String length:", length)
    
    // 调用结构体相关函数
    point := C.create_point(3, 4)
    defer C.free_point(point)
    distance := C.point_distance(point)
    fmt.Println("Distance squared:", distance)
}
```

### 3.3 调用 C 函数指针

```go
package main

/*
#include <stdlib.h>

// 定义函数指针类型
typedef int (*callback_t)(int);

// 使用函数指针的函数
int apply_callback(callback_t cb, int value) {
    return cb(value);
}

// C 函数作为回调
int double_value(int x) {
    return x * 2;
}
*/
import "C"
import "fmt"

func main() {
    // 使用 C 函数作为回调
    result := C.apply_callback((*[0]byte)(C.double_value), 5)
    fmt.Println("Result:", result)
}
```

### 3.4 调用可变参数 C 函数

```go
package main

/*
#include <stdio.h>
#include <stdarg.h>

// 包装可变参数函数
int my_printf(const char *format, ...) {
    va_list args;
    va_start(args, format);
    int result = vprintf(format, args);
    va_end(args);
    return result;
}

// 或者提供固定参数版本
int print_int(const char *prefix, int value) {
    return printf("%s: %d\n", prefix, value);
}
*/
import "C"
import "fmt"

func main() {
    // Go 不能直接调用可变参数 C 函数
    // 需要在 C 侧提供包装函数
    
    // 使用包装函数
    prefix := C.CString("Value")
    defer C.free(unsafe.Pointer(prefix))
    C.print_int(prefix, 42)
}
```

---

## 四、C 调用 Go 函数

### 4.1 导出 Go 函数

```go
package main

import "C"
import "fmt"

//export Add
func Add(a, b C.int) C.int {
    return a + b
}

//export Greet
func Greet(name *C.char) *C.char {
    goName := C.GoString(name)
    greeting := "Hello, " + goName + "!"
    return C.CString(greeting)
}

//export ProcessArray
func ProcessArray(arr *C.int, length C.int) C.int {
    // 将 C 数组转换为 Go 切片
    slice := (*[1 << 30]C.int)(unsafe.Pointer(arr))[:length:length]
    
    sum := C.int(0)
    for _, v := range slice {
        sum += v
    }
    return sum
}

func main() {
    // 导出的函数需要 main 函数存在
    // 当构建为共享库时，main 不会被调用
}
```

### 4.2 构建共享库

```bash
# 构建 C 共享库
go build -buildmode=c-shared -o libmylib.so mylib.go

# 这会生成：
# - libmylib.so   (共享库)
# - libmylib.h    (C 头文件，包含导出函数的声明)
```

生成的头文件示例：
```c
// libmylib.h
#ifdef __cplusplus
extern "C" {
#endif

extern int Add(int a, int b);
extern char* Greet(char* name);
extern int ProcessArray(int* arr, int length);

#ifdef __cplusplus
}
#endif
```

### 4.3 C 程序调用 Go 共享库

```c
// main.c
#include <stdio.h>
#include "libmylib.h"

int main() {
    // 调用 Go 函数
    int result = Add(10, 20);
    printf("Add result: %d\n", result);
    
    // 调用字符串处理函数
    char* greeting = Greet("World");
    printf("%s\n", greeting);
    // 注意：Go 返回的 C 字符串需要手动释放
    // 或者使用 Go 提供的释放函数
    
    // 调用数组处理函数
    int arr[] = {1, 2, 3, 4, 5};
    int sum = ProcessArray(arr, 5);
    printf("Array sum: %d\n", sum);
    
    return 0;
}
```

编译 C 程序：
```bash
gcc -o main main.c -L. -lmylib -Wl,-rpath,.
./main
```

### 4.4 导出 Go 结构体

```go
package main

/*
#include <stdlib.h>
*/
import "C"
import "unsafe"

// Go 结构体
type Point struct {
    X, Y int
}

//export NewPoint
func NewPoint(x, y C.int) *Point {
    return &Point{int(x), int(y)}
}

//export PointGetX
func PointGetX(p *Point) C.int {
    return C.int(p.X)
}

//export PointGetY
func PointGetY(p *Point) C.int {
    return C.int(p.Y)
}

//export PointSetX
func PointSetX(p *Point, x C.int) {
    p.X = int(x)
}

//export PointSetY
func PointSetY(p *Point, y C.int) {
    p.Y = int(y)
}

//export PointDistance
func PointDistance(p *Point) C.double {
    // 返回到原点的距离
    return C.sqrt(C.double(p.X*p.X + p.Y*p.Y))
}

//export FreePoint
func FreePoint(p *Point) {
    // Go 的 GC 会自动回收，但如果需要显式释放
    // 可以在这里处理
}

func main() {}
```

---

## 五、数据类型转换

### 5.1 基本类型映射

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                           C 与 Go 基本类型映射                                   │
├─────────────────────────────────────────────────────────────────────────────────┤
│                                                                                 │
│  C 类型                    Go 类型              说明                             │
│  ─────────────────────────────────────────────────────────────────────────────  │
│  char                     C.char              有符号字符                        │
│  unsigned char            C.uchar             无符号字符                        │
│  signed char              C.schar             有符号字符                        │
│  short                    C.short             短整型                            │
│  unsigned short           C.ushort            无符号短整型                      │
│  int                      C.int               整型                              │
│  unsigned int             C.uint              无符号整型                        │
│  long                     C.long              长整型                            │
│  unsigned long            C.ulong             无符号长整型                      │
│  long long                C.longlong          长长整型                          │
│  unsigned long long       C.ulonglong         无符号长长整型                    │
│  float                    C.float             单精度浮点                        │
│  double                   C.double            双精度浮点                        │
│  void*                    unsafe.Pointer      通用指针                          │
│  char*                    *C.char             C 字符串                          │
│                                                                                 │
└─────────────────────────────────────────────────────────────────────────────────┘
```

### 5.2 字符串转换

```go
package main

/*
#include <stdlib.h>
#include <string.h>
*/
import "C"
import (
    "fmt"
    "unsafe"
)

func main() {
    // ========== Go 字符串 → C 字符串 ==========
    
    // 方法 1：C.CString (需要手动释放)
    goStr := "Hello, C!"
    cStr := C.CString(goStr)
    defer C.free(unsafe.Pointer(cStr))  // 必须手动释放！
    fmt.Println("C string:", C.GoString(cStr))
    
    // 方法 2：C.CBytes (用于字节切片)
    goBytes := []byte{1, 2, 3, 4, 5}
    cBytes := C.CBytes(goBytes)
    defer C.free(cBytes)  // 必须手动释放！
    
    // ========== C 字符串 → Go 字符串 ==========
    
    // 方法 1：C.GoString (以 null 结尾的字符串)
    var cStr2 *C.char = C.CString("Hello, Go!")
    defer C.free(unsafe.Pointer(cStr2))
    goStr2 := C.GoString(cStr2)
    fmt.Println("Go string:", goStr2)
    
    // 方法 2：C.GoStringN (指定长度)
    goStr3 := C.GoStringN(cStr2, 5)  // 只取前 5 个字符
    fmt.Println("Go string (5 chars):", goStr3)
    
    // 方法 3：C.GoBytes (转换为字节切片)
    cBytes2 := (*C.char)(C.malloc(5))
    defer C.free(unsafe.Pointer(cBytes2))
    // 填充数据...
    goBytes2 := C.GoBytes(unsafe.Pointer(cBytes2), 5)
    fmt.Println("Go bytes:", goBytes2)
}
```

### 5.3 数组转换

```go
package main

/*
#include <stdlib.h>
*/
import "C"
import (
    "fmt"
    "unsafe"
)

func main() {
    // ========== Go 数组/切片 → C 数组 ==========
    
    // Go 切片
    goSlice := []int{1, 2, 3, 4, 5}
    
    // 方法 1：传递指针（不复制，但需要确保 Go 数据不被移动）
    // 注意：这种方式只在 CGO 调用期间安全
    cArrayPtr := (*C.int)(unsafe.Pointer(&goSlice[0]))
    
    // 方法 2：复制到 C 内存
    cArray := (*C.int)(C.malloc(C.size_t(len(goSlice) * int(unsafe.Sizeof(C.int(0))))))
    defer C.free(unsafe.Pointer(cArray))
    
    // 复制数据
    goSliceHeader := (*[1 << 30]C.int)(unsafe.Pointer(cArray))[:len(goSlice):len(goSlice)]
    for i, v := range goSlice {
        goSliceHeader[i] = C.int(v)
    }
    
    // ========== C 数组 → Go 切片 ==========
    
    // 方法 1：使用 unsafe.Slice (Go 1.17+)
    cArray2 := (*C.int)(C.malloc(5 * C.size_t(unsafe.Sizeof(C.int(0)))))
    defer C.free(unsafe.Pointer(cArray2))
    
    // 填充 C 数组
    for i := 0; i < 5; i++ {
        *(*C.int)(unsafe.Pointer(uintptr(unsafe.Pointer(cArray2)) + uintptr(i)*unsafe.Sizeof(C.int(0)))) = C.int(i * 10)
    }
    
    // 转换为 Go 切片
    goSlice2 := unsafe.Slice(cArray2, 5)
    fmt.Println("Go slice from C array:", goSlice2)
    
    // 方法 2：使用反射 (旧版本 Go)
    // import "reflect"
    // sliceHeader := reflect.SliceHeader{
    //     Data: uintptr(unsafe.Pointer(cArray2)),
    //     Len:  5,
    //     Cap:  5,
    // }
    // goSlice3 := *(*[]C.int)(unsafe.Pointer(&sliceHeader))
}
```

### 5.4 结构体转换

```go
package main

/*
#include <stdlib.h>
#include <string.h>

// C 结构体
typedef struct {
    int id;
    char name[64];
    double score;
} CStudent;

// C 结构体（带指针）
typedef struct {
    int count;
    int *data;
} CArray;
*/
import "C"
import (
    "fmt"
    "unsafe"
)

// Go 结构体（对应 C 结构体）
type GoStudent struct {
    ID    int
    Name  string
    Score float64
}

// Go 结构体（带切片）
type GoArray struct {
    Count int
    Data  []int
}

func main() {
    // ========== Go 结构体 → C 结构体 ==========
    
    goStudent := GoStudent{
        ID:    1,
        Name:  "Alice",
        Score: 95.5,
    }
    
    // 创建 C 结构体
    var cStudent C.CStudent
    cStudent.id = C.int(goStudent.ID)
    cStudent.score = C.double(goStudent.Score)
    
    // 复制字符串
    nameCStr := C.CString(goStudent.Name)
    defer C.free(unsafe.Pointer(nameCStr))
    C.strcpy(&cStudent.name[0], nameCStr)
    
    fmt.Printf("C Student: id=%d, name=%s, score=%.1f\n",
        cStudent.id, C.GoString(&cStudent.name[0]), cStudent.score)
    
    // ========== C 结构体 → Go 结构体 ==========
    
    var cStudent2 C.CStudent
    cStudent2.id = 2
    C.strcpy(&cStudent2.name[0], C.CString("Bob"))
    cStudent2.score = 88.0
    
    goStudent2 := GoStudent{
        ID:    int(cStudent2.id),
        Name:  C.GoString(&cStudent2.name[0]),
        Score: float64(cStudent2.score),
    }
    fmt.Printf("Go Student: %+v\n", goStudent2)
    
    // ========== 带指针的结构体 ==========
    
    goArray := GoArray{
        Count: 5,
        Data:  []int{1, 2, 3, 4, 5},
    }
    
    // 创建 C 结构体
    var cArray C.CArray
    cArray.count = C.int(goArray.Count)
    cArray.data = (*C.int)(C.malloc(C.size_t(goArray.Count) * C.size_t(unsafe.Sizeof(C.int(0)))))
    defer C.free(unsafe.Pointer(cArray.data))
    
    // 复制数据
    for i, v := range goArray.Data {
        (*[1 << 30]C.int)(unsafe.Pointer(cArray.data))[i] = C.int(v)
    }
}
```

### 5.5 类型转换辅助函数

```go
package main

import "C"
import (
    "reflect"
    "unsafe"
)

// GoBytesToC 将 Go []byte 转换为 C 的 void* 和长度
func GoBytesToC(b []byte) (unsafe.Pointer, C.size_t) {
    if len(b) == 0 {
        return nil, 0
    }
    return unsafe.Pointer(&b[0]), C.size_t(len(b))
}

// CBytesToGo 将 C 的 void* 和长度转换为 Go []byte
func CBytesToGo(ptr unsafe.Pointer, length C.size_t) []byte {
    if ptr == nil || length == 0 {
        return nil
    }
    return (*[1 << 30]byte)(ptr)[:length:length]
}

// GoStringToC 将 Go string 转换为 C 字符串（需要释放）
func GoStringToC(s string) *C.char {
    return C.CString(s)
}

// CStringToGo 将 C 字符串转换为 Go string
func CStringToGo(s *C.char) string {
    return C.GoString(s)
}

// GoSliceToCArray 将 Go 切片转换为 C 数组指针
func GoSliceToCArray[T any](slice []T) unsafe.Pointer {
    if len(slice) == 0 {
        return nil
    }
    return unsafe.Pointer(&slice[0])
}

// CArrayToGoSlice 将 C 数组指针转换为 Go 切片
func CArrayToGoSlice[T any](ptr unsafe.Pointer, length int) []T {
    if ptr == nil || length == 0 {
        return nil
    }
    
    var zero T
    size := unsafe.Sizeof(zero)
    
    sliceHeader := reflect.SliceHeader{
        Data: uintptr(ptr),
        Len:  length,
        Cap:  length,
    }
    return *(*[]T)(unsafe.Pointer(&sliceHeader))
}
```

---

## 六、内存管理

### 6.1 内存分配与释放

```go
package main

/*
#include <stdlib.h>
#include <string.h>
*/
import "C"
import (
    "fmt"
    "unsafe"
)

func main() {
    // ========== C 内存管理 ==========
    
    // 1. malloc/free
    ptr := C.malloc(100)
    if ptr == nil {
        panic("malloc failed")
    }
    defer C.free(ptr)  // 确保释放
    
    // 2. calloc (分配并清零)
    ptr2 := C.calloc(10, C.size_t(unsafe.Sizeof(C.int(0))))
    defer C.free(ptr2)
    
    // 3. realloc (重新分配)
    ptr3 := C.malloc(100)
    ptr3 = C.realloc(ptr3, 200)  // 扩展到 200 字节
    defer C.free(ptr3)
    
    // ========== Go 内存管理 ==========
    
    // Go 的内存由 GC 管理，不需要手动释放
    goSlice := make([]byte, 100)
    
    // 但如果将 Go 内存传递给 C，需要确保：
    // 1. Go 数据在 C 使用期间不被 GC 回收
    // 2. 使用 runtime.KeepAlive 保持引用
    
    // 示例：传递 Go 切片给 C 函数
    cFunc := func(data []byte) {
        // 使用 runtime.Pinner (Go 1.21+) 固定内存
        // 或者复制到 C 内存
        
        // 方法 1：复制到 C 内存（推荐）
        cData := C.CBytes(data)
        defer C.free(cData)
        // 使用 cData...
    }
    
    // 方法 2：使用 runtime.KeepAlive
    // 确保在 C 函数返回前 Go 数据不被回收
}
```

### 6.2 内存安全规则

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                           CGO 内存安全规则                                       │
├─────────────────────────────────────────────────────────────────────────────────┤
│                                                                                 │
│  规则 1：C.CString / C.CBytes 分配的内存必须手动释放                             │
│  ─────────────────────────────────────────────────────────────────────────────  │
│  cstr := C.CString("hello")                                                     │
│  defer C.free(unsafe.Pointer(cstr))  // ✅ 正确                                 │
│  // 不释放会导致内存泄漏 ❌                                                       │
│                                                                                 │
│  规则 2：C.GoString / C.GoBytes 会复制数据，不需要释放                            │
│  ─────────────────────────────────────────────────────────────────────────────  │
│  gostr := C.GoString(cstr)           // ✅ 复制数据                              │
│  // gostr 由 Go GC 管理，不需要手动释放                                          │
│                                                                                 │
│  规则 3：不要在 Go 中释放 C 分配的内存后继续使用                                   │
│  ─────────────────────────────────────────────────────────────────────────────  │
│  ptr := C.malloc(100)                                                           │
│  C.free(ptr)                                                                    │
│  // 使用 ptr...  // ❌ 危险！悬空指针                                            │
│                                                                                 │
│  规则 4：不要在 C 中释放 Go 分配的内存                                            │
│  ─────────────────────────────────────────────────────────────────────────────  │
│  slice := make([]byte, 100)                                                     │
│  ptr := unsafe.Pointer(&slice[0])                                               │
│  C.free(ptr)  // ❌ 错误！Go 内存由 GC 管理                                      │
│                                                                                 │
│  规则 5：传递给 C 的 Go 指针必须在调用期间有效                                     │
│  ─────────────────────────────────────────────────────────────────────────────  │
│  func bad() {                                                                   │
│      data := make([]byte, 100)                                                  │
│      return unsafe.Pointer(&data[0])  // ❌ 返回后 data 可能被 GC               │
│  }                                                                              │
│                                                                                 │
│  func good() unsafe.Pointer {                                                   │
│      data := C.malloc(100)                                                      │
│      return data  // ✅ C 内存不受 GC 影响                                       │
│  }                                                                              │
│                                                                                 │
└─────────────────────────────────────────────────────────────────────────────────┘
```

### 6.3 内存泄漏检测

```go
package main

/*
#include <stdlib.h>

// 跟踪内存分配
#ifdef DEBUG
#define MALLOC(size) debug_malloc(size, __FILE__, __LINE__)
#define FREE(ptr) debug_free(ptr, __FILE__, __LINE__)

void* debug_malloc(size_t size, const char* file, int line) {
    void* ptr = malloc(size);
    printf("MALLOC: %p (%zu bytes) at %s:%d\n", ptr, size, file, line);
    return ptr;
}

void debug_free(void* ptr, const char* file, int line) {
    printf("FREE: %p at %s:%d\n", ptr, file, line);
    free(ptr);
}
#else
#define MALLOC(size) malloc(size)
#define FREE(ptr) free(ptr)
#endif
*/
import "C"
import (
    "fmt"
    "unsafe"
)

func main() {
    // 使用调试宏
    ptr := C.MALLOC(100)
    defer C.FREE(ptr)
    
    fmt.Println("Memory allocated")
}
```

---

## 七、回调函数

### 7.1 C 调用 Go 回调函数

```go
package main

/*
#include <stdlib.h>

// 定义回调函数类型
typedef int (*callback_t)(int, int);

// 存储回调函数
static callback_t g_callback = NULL;

// 设置回调函数
void set_callback(callback_t cb) {
    g_callback = cb;
}

// 调用回调函数
int call_callback(int a, int b) {
    if (g_callback != NULL) {
        return g_callback(a, b);
    }
    return -1;
}
*/
import "C"
import "fmt"

// 导出 Go 函数作为回调
//export myCallback
func myCallback(a, b C.int) C.int {
    fmt.Printf("Go callback called with a=%d, b=%d\n", a, b)
    return a + b
}

func main() {
    // 设置回调函数
    C.set_callback((*[0]byte)(C.myCallback))
    
    // 调用回调
    result := C.call_callback(10, 20)
    fmt.Println("Result:", result)
}
```

### 7.2 Go 调用 C 回调函数

```go
package main

/*
#include <stdlib.h>

// C 回调函数
int c_callback(int a, int b) {
    return a * b;
}

// 使用回调的函数
typedef int (*operation_t)(int, int);

int apply_operation(operation_t op, int a, int b) {
    return op(a, b);
}
*/
import "C"
import "fmt"

func main() {
    // 调用 C 函数，传递 C 回调
    result := C.apply_operation((*[0]byte)(C.c_callback), 5, 6)
    fmt.Println("Result:", result)
}
```

### 7.3 动态回调注册

```go
package main

/*
#include <stdlib.h>
#include <string.h>

#define MAX_CALLBACKS 10

typedef void (*event_callback_t)(const char* event, void* data);

static event_callback_t callbacks[MAX_CALLBACKS];
static const char* event_names[MAX_CALLBACKS];
static int callback_count = 0;

int register_callback(const char* event, event_callback_t cb) {
    if (callback_count >= MAX_CALLBACKS) {
        return -1;
    }
    event_names[callback_count] = event;
    callbacks[callback_count] = cb;
    return callback_count++;
}

void trigger_event(const char* event, void* data) {
    for (int i = 0; i < callback_count; i++) {
        if (strcmp(event_names[i], event) == 0) {
            callbacks[i](event, data);
        }
    }
}
*/
import "C"
import (
    "fmt"
    "unsafe"
)

// 导出的 Go 回调函数
//export onConnect
func onConnect(event *C.char, data unsafe.Pointer) {
    fmt.Printf("Go: Connect event triggered: %s\n", C.GoString(event))
}

//export onDisconnect
func onDisconnect(event *C.char, data unsafe.Pointer) {
    fmt.Printf("Go: Disconnect event triggered: %s\n", C.GoString(event))
}

func main() {
    // 注册回调
    connectEvent := C.CString("connect")
    defer C.free(unsafe.Pointer(connectEvent))
    
    disconnectEvent := C.CString("disconnect")
    defer C.free(unsafe.Pointer(disconnectEvent))
    
    C.register_callback(connectEvent, (*[0]byte)(C.onConnect))
    C.register_callback(disconnectEvent, (*[0]byte)(C.onDisconnect))
    
    // 触发事件
    C.trigger_event(connectEvent, nil)
    C.trigger_event(disconnectEvent, nil)
}
```

---

## 八、构建共享库

### 8.1 构建模式

```bash
# 1. C 共享库（供 C 程序调用）
go build -buildmode=c-shared -o libmylib.so mylib.go

# 2. C 静态库（供 C 程序链接）
go build -buildmode=c-archive -o libmylib.a mylib.go

# 3. PIE 可执行文件（位置无关）
go build -buildmode=pie -o myapp main.go

# 4. 插件模式
go build -buildmode=plugin -o myplugin.so myplugin.go
```

### 8.2 完整示例：构建共享库

```go
// calculator.go
package main

import "C"
import (
    "fmt"
    "sync"
)

var (
    counter int
    mu      sync.Mutex
)

//export Initialize
func Initialize() {
    fmt.Println("Calculator initialized")
}

//export Add
func Add(a, b C.int) C.int {
    return a + b
}

//export Subtract
func Subtract(a, b C.int) C.int {
    return a - b
}

//export Multiply
func Multiply(a, b C.int) C.int {
    return a * b
}

//export Divide
func Divide(a, b C.int) C.int {
    if b == 0 {
        return 0
    }
    return a / b
}

//export IncrementCounter
func IncrementCounter() C.int {
    mu.Lock()
    defer mu.Unlock()
    counter++
    return C.int(counter)
}

//export GetCounter
func GetCounter() C.int {
    mu.Lock()
    defer mu.Unlock()
    return C.int(counter)
}

//export Cleanup
func Cleanup() {
    fmt.Println("Calculator cleaned up")
}

func main() {
    // 构建为共享库时，main 函数不会被调用
    // 但必须存在
}
```

构建和测试：
```bash
# 构建
go build -buildmode=c-shared -o libcalculator.so calculator.go

# 生成的头文件 calculator.h
cat calculator.h

# C 测试程序
cat > test.c << 'EOF'
#include <stdio.h>
#include "calculator.h"

int main() {
    Initialize();
    
    printf("Add(10, 20) = %d\n", Add(10, 20));
    printf("Subtract(30, 10) = %d\n", Subtract(30, 10));
    printf("Multiply(5, 6) = %d\n", Multiply(5, 6));
    printf("Divide(20, 4) = %d\n", Divide(20, 4));
    
    printf("Counter: %d\n", IncrementCounter());
    printf("Counter: %d\n", IncrementCounter());
    printf("Counter: %d\n", GetCounter());
    
    Cleanup();
    return 0;
}
EOF

# 编译和运行
gcc -o test test.c -L. -lcalculator -Wl,-rpath,.
./test
```

### 8.3 跨平台构建

```bash
# Linux AMD64
GOOS=linux GOARCH=amd64 go build -buildmode=c-shared -o libcalculator_linux_amd64.so calculator.go

# Linux ARM64
GOOS=linux GOARCH=arm64 go build -buildmode=c-shared -o libcalculator_linux_arm64.so calculator.go

# macOS
GOOS=darwin GOARCH=amd64 go build -buildmode=c-shared -o libcalculator_darwin_amd64.dylib calculator.go

# Windows
GOOS=windows GOARCH=amd64 go build -buildmode=c-shared -o calculator.dll calculator.go
```

---

## 九、实战案例

### 9.1 案例：封装 C 库

```go
// sqlite_wrapper.go
package sqlite

/*
#cgo LDFLAGS: -lsqlite3
#include <sqlite3.h>
#include <stdlib.h>
*/
import "C"
import (
    "errors"
    "unsafe"
)

type Database struct {
    db *C.sqlite3
}

type Statement struct {
    stmt *C.sqlite3_stmt
}

func Open(filename string) (*Database, error) {
    cfilename := C.CString(filename)
    defer C.free(unsafe.Pointer(cfilename))
    
    var db *C.sqlite3
    result := C.sqlite3_open(cfilename, &db)
    if result != C.SQLITE_OK {
        return nil, errors.New(C.GoString(C.sqlite3_errmsg(db)))
    }
    
    return &Database{db: db}, nil
}

func (d *Database) Close() error {
    result := C.sqlite3_close(d.db)
    if result != C.SQLITE_OK {
        return errors.New(C.GoString(C.sqlite3_errmsg(d.db)))
    }
    return nil
}

func (d *Database) Exec(sql string) error {
    csql := C.CString(sql)
    defer C.free(unsafe.Pointer(csql))
    
    var errmsg *C.char
    result := C.sqlite3_exec(d.db, csql, nil, nil, &errmsg)
    if result != C.SQLITE_OK {
        defer C.sqlite3_free(unsafe.Pointer(errmsg))
        return errors.New(C.GoString(errmsg))
    }
    return nil
}

func (d *Database) Prepare(sql string) (*Statement, error) {
    csql := C.CString(sql)
    defer C.free(unsafe.Pointer(csql))
    
    var stmt *C.sqlite3_stmt
    result := C.sqlite3_prepare_v2(d.db, csql, -1, &stmt, nil)
    if result != C.SQLITE_OK {
        return nil, errors.New(C.GoString(C.sqlite3_errmsg(d.db)))
    }
    
    return &Statement{stmt: stmt}, nil
}

func (s *Statement) BindInt(index int, value int) error {
    result := C.sqlite3_bind_int(s.stmt, C.int(index), C.int(value))
    if result != C.SQLITE_OK {
        return errors.New("bind int failed")
    }
    return nil
}

func (s *Statement) Step() bool {
    return C.sqlite3_step(s.stmt) == C.SQLITE_ROW
}

func (s *Statement) ColumnInt(index int) int {
    return int(C.sqlite3_column_int(s.stmt, C.int(index)))
}

func (s *Statement) ColumnText(index int) string {
    return C.GoString((*C.char)(unsafe.Pointer(C.sqlite3_column_text(s.stmt, C.int(index)))))
}

func (s *Statement) Finalize() error {
    result := C.sqlite3_finalize(s.stmt)
    if result != C.SQLITE_OK {
        return errors.New("finalize failed")
    }
    return nil
}
```

### 9.2 案例：高性能数据处理

```go
// dataprocessor.go
package main

/*
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

// 高性能数据处理函数
void process_int_array(int* data, int length, int multiplier) {
    for (int i = 0; i < length; i++) {
        data[i] *= multiplier;
    }
}

// 批量处理结构体
typedef struct {
    int32_t* values;
    int length;
    int sum;
    double average;
} IntArrayResult;

IntArrayResult process_and_analyze(int32_t* data, int length) {
    IntArrayResult result;
    result.values = (int32_t*)malloc(length * sizeof(int32_t));
    result.length = length;
    result.sum = 0;
    
    for (int i = 0; i < length; i++) {
        result.values[i] = data[i] * 2;  // 处理数据
        result.sum += result.values[i];
    }
    result.average = (double)result.sum / length;
    
    return result;
}

void free_result(IntArrayResult* result) {
    free(result->values);
}
*/
import "C"
import (
    "fmt"
    "unsafe"
)

func main() {
    // 准备数据
    data := []int32{1, 2, 3, 4, 5, 6, 7, 8, 9, 10}
    
    // 调用 C 函数处理
    cData := (*C.int32_t)(unsafe.Pointer(&data[0]))
    C.process_int_array(cData, C.int(len(data)), 10)
    
    fmt.Println("Processed data:", data)
    
    // 分析数据
    result := C.process_and_analyze(cData, C.int(len(data)))
    defer C.free_result(&result)
    
    fmt.Printf("Sum: %d, Average: %.2f\n", result.sum, result.average)
    
    // 获取处理后的数据
    processedData := unsafe.Slice(result.values, result.length)
    fmt.Println("Processed values:", processedData)
}
```

---

## 十、常见问题与陷阱

### 10.1 常见错误

```go
package main

/*
#include <stdlib.h>
*/
import "C"
import "unsafe"

func main() {
    // ❌ 错误 1：忘记释放 C 内存
    cstr := C.CString("hello")
    // 缺少 defer C.free(unsafe.Pointer(cstr))
    
    // ❌ 错误 2：使用已释放的内存
    ptr := C.malloc(100)
    C.free(ptr)
    // 使用 ptr... // 危险！
    
    // ❌ 错误 3：Go 指针传递给 C 后被 GC
    goSlice := make([]byte, 100)
    goPtr := unsafe.Pointer(&goSlice[0])
    // goSlice 可能被 GC，goPtr 变成悬空指针
    
    // ❌ 错误 4：类型不匹配
    var i int = 100
    // C.some_func(C.int(i))  // 正确
    // C.some_func(i)  // 错误：int 和 C.int 是不同类型
    
    // ❌ 错误 5：字符串未正确转换
    // C.printf("hello")  // 错误：Go 字符串不能直接传给 C
    C.printf(C.CString("hello"))  // 正确
}
```

### 10.2 性能优化

```go
package main

/*
#include <stdlib.h>
#include <string.h>
*/
import "C"
import (
    "unsafe"
)

// ❌ 低效：频繁分配释放
func processStringsLowEfficiency(strs []string) {
    for _, s := range strs {
        cstr := C.CString(s)
        // 使用 cstr...
        C.free(unsafe.Pointer(cstr))
    }
}

// ✅ 高效：预分配缓冲区
func processStringsHighEfficiency(strs []string) {
    // 找到最大长度
    maxLen := 0
    for _, s := range strs {
        if len(s) > maxLen {
            maxLen = len(s)
        }
    }
    
    // 预分配缓冲区
    buf := (*C.char)(C.malloc(C.size_t(maxLen + 1)))
    defer C.free(unsafe.Pointer(buf))
    
    for _, s := range strs {
        C.memcpy(unsafe.Pointer(buf), unsafe.Pointer(unsafe.StringData(s)), C.size_t(len(s)))
        *(*byte)(unsafe.Pointer(uintptr(unsafe.Pointer(buf)) + uintptr(len(s)))) = 0
        // 使用 buf...
    }
}

// ✅ 高效：批量处理
func batchProcess(data []int, batchSize int) {
    for i := 0; i < len(data); i += batchSize {
        end := i + batchSize
        if end > len(data) {
            end = len(data)
        }
        
        batch := data[i:end]
        cData := (*C.int)(unsafe.Pointer(&batch[0]))
        // 批量处理...
        _ = cData
    }
}
```

### 10.3 调试技巧

```go
package main

/*
#include <stdio.h>

#define DEBUG_PRINT(fmt, ...) \
    do { fprintf(stderr, "[DEBUG] " fmt "\n", ##__VA_ARGS__); } while(0)
*/
import "C"
import (
    "runtime/debug"
    "unsafe"
)

func main() {
    // 1. 使用 C 打印调试
    C.DEBUG_PRINT(C.CString("Starting program"))
    
    // 2. 打印 CGO 调用栈
    debug.PrintStack()
    
    // 3. 检查内存使用
    var m debug.GCStats
    debug.ReadGCStats(&m)
    
    // 4. 强制 GC 测试内存问题
    debug.SetGCPercent(1)  // 更频繁的 GC
    debug.FreeOSMemory()   // 释放内存给 OS
}
```

---

## 附录：快速参考

### A. CGO 编译标志

```go
// #cgo CFLAGS: -I/path/to/include
// #cgo LDFLAGS: -L/path/to/lib -lmylib
// #cgo pkg-config: mylib
import "C"
```

### B. 类型转换速查

| Go 类型 | C 类型 | 转换方法 |
|---------|--------|----------|
| string | char* | C.CString(s) / C.GoString(cs) |
| []byte | void* | C.CBytes(b) / C.GoBytes(p, n) |
| int | int | C.int(i) / int(ci) |
| unsafe.Pointer | void* | 直接使用 |

### C. 内存管理速查

| 函数 | 分配者 | 释放者 |
|------|--------|--------|
| C.CString | Go | 手动 C.free |
| C.CBytes | Go | 手动 C.free |
| C.GoString | Go | Go GC |
| C.GoBytes | Go | Go GC |
| C.malloc | C | 手动 C.free |
| make | Go | Go GC |

### D. 常用命令

```bash
# 查看 CGO 生成的文件
go tool cgo main.go

# 查看编译过程
go build -x

# 静态链接
go build -ldflags '-extldflags "-static"'

# 查看符号表
nm libmylib.so

# 查看依赖
ldd libmylib.so
```
