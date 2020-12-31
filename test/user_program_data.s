.section .text
.globl entry
entry:
    mov %cr3, %eax
    mov %eax, %cr3
    mov item1, %eax
    mov item2, %ebx
loop:
    jmp loop

.section .data
item1: .long 0xCAFE
item2: .long 0xBEEF
