" ~/.config/nvim/init.vim

" " --- Vim-Plug --- " "
call plug#begin(stdpath('data') . '/plugged')

" " Plugins " "
Plug 'sheerun/vim-polyglot'
Plug 'tpope/vim-commentary'
Plug 'tpope/vim-fugitive'

" " Theme " "
Plug 'itchyny/lightline.vim'
Plug 'sonph/onehalf', { 'rtp': 'vim' }

call plug#end()

" " --- Config --- " "
"
syntax on
set background=dark
set colorcolumn=80
set cursorline
set encoding=utf-8
set incsearch
set nobackup
set noerrorbells
set noshowmode
set noswapfile
set nowrap
set number relativenumber
set smartcase
set smartindent
set splitbelow splitright
set tabstop=2 softtabstop=2 shiftwidth=2
set termguicolors t_Co=256
set undodir=~/.local/share/nvim/undodir
set undofile

let &t_8f = "\<Esc>[38;2;%lu;%lu;%lum"
let &t_8b = "\<Esc>[48;2;%lu;%lu;%lum"

" " Color Scheme Config " "
"
let g:lightline = {
      \ 'colorscheme': 'wombat',
      \ 'active': {
      \   'left': [ [ 'mode', 'paste' ],
      \             [ 'gitbranch', 'readonly', 'filename', 'modified' ] ]
      \ },
      \ 'component_function': {
      \   'fileformat': 'LightlineFileformat',
      \   'filetype': 'LightlineFiletype',
      \   'gitbranch': 'FugitiveHead',
      \ },
      \ }

function! LightlineFileformat()
  return winwidth(0) > 70 ? &fileformat : ''
endfunction

function! LightlineFiletype()
  return winwidth(0) > 70 ? (&filetype !=# '' ? &filetype : 'no ft') : ''
endfunction

colorscheme onehalfdark

" " Key Mapping " "
"
let mapleader = " "

nnoremap <silent> <C-_> :Commentary<CR>
inoremap <silent> <C-_> <C-o>:Commentary<CR>

tnoremap <Esc> <C-\><C-n>
