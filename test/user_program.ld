ENTRY(entry)

SECTIONS {

	.data ALIGN(4K) : {
		*(.data)
	}

	.text ALIGN(4K) : {
		*(.text)
	}
}
