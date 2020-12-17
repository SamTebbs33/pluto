.section .text
.globl entry
entry:
    nop
    mov item1, %eax
    mov item2, %ebx
loop:
    jmp loop

.section .data
item1: .long 0xCAFE
item2: .long 0xBEEF
